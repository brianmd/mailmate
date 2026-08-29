# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/mcp"
require "tmpdir"

# Tests for the in-process MCP dispatch layer: dispatch never lets an
# in-process CLI crash the loop, argv synthesis threads the documented
# options through, and — end-to-end over real pipes — compose subprocesses
# never touch the JSON-RPC transport fds.
class TestMCP < Minitest::Test
  include Mailmate::TestHelpers

  S = Mailmate::MCP

  # ---- dispatch resilience ----

  def test_dispatch_unknown_tool_is_an_error_not_a_raise
    res = S.dispatch("nope", {})
    assert res[:isError]
    assert_match(/Unknown tool/, res[:content].first[:text])
  end

  def test_dispatch_survives_standard_error
    S.stub(:call_search, ->(_a) { raise "boom" }) do
      res = S.dispatch("search", {})
      assert res[:isError]
      assert_match(/RuntimeError: boom/, res[:content].first[:text])
    end
  end

  def test_dispatch_survives_system_exit
    # A CLI path that calls exit/abort (e.g. a missing optional gem) must be
    # contained — SystemExit isn't a StandardError, so this is the clause that
    # keeps the persistent server alive.
    S.stub(:call_message, ->(_a) { exit 3 }) do
      res = S.dispatch("message", {})
      assert res[:isError]
      assert_match(/exit\(3\)/, res[:content].first[:text])
      assert_match(/server still running/, res[:content].first[:text])
    end
  end

  # ---- argv synthesis ----

  def test_call_message_threads_markdown_flag
    captured = nil
    S.stub(:run_cli, ->(_mod, argv) { captured = argv; { content: [], isError: false } }) do
      S.call_message("id" => "123", "markdown" => true)
    end
    assert_equal ["123", "--markdown"], captured
  end

  def test_call_message_omits_markdown_when_absent
    captured = nil
    S.stub(:run_cli, ->(_mod, argv) { captured = argv; { content: [], isError: false } }) do
      S.call_message("id" => "123")
    end
    assert_equal ["123"], captured
  end

  def test_call_modify_check_inline_maps_to_check_flag
    captured = nil
    S.stub(:run_cli, ->(_mod, argv) { captured = argv; { content: [], isError: false } }) do
      S.call_modify("id" => "1", "actions" => ["read"], "check" => "inline")
    end
    assert_includes captured, "--check"
    refute_includes captured, "--emit-check"
  end

  def test_call_modify_check_defer_maps_to_emit_check_flag
    captured = nil
    S.stub(:run_cli, ->(_mod, argv) { captured = argv; { content: [], isError: false } }) do
      S.call_modify("id" => "1", "actions" => ["read"], "check" => "defer")
    end
    assert_includes captured, "--emit-check"
    refute_includes captured, "--check"
  end

  def test_call_modify_check_none_adds_no_verification_flag
    captured = nil
    S.stub(:run_cli, ->(_mod, argv) { captured = argv; { content: [], isError: false } }) do
      S.call_modify("id" => "1", "actions" => ["read"], "check" => "none")
    end
    refute_includes captured, "--check"
    refute_includes captured, "--emit-check"
  end

  def test_call_verify_pipes_tickets_on_stdin
    seen_stdin = nil
    mod = nil
    S.stub(:run_cli, lambda do |m, _argv|
      mod = m
      seen_stdin = $stdin.read
      { content: [], isError: false }
    end) do
      S.call_verify("tickets" => [{ "eml_id" => 1, "expectations" => [] }])
    end
    assert_equal Mailmate::CLI::Verify, mod
    assert_equal [{ "eml_id" => 1, "expectations" => [] }], JSON.parse(seen_stdin)
  end

  # ---- transport fd hygiene (end-to-end) ----

  # Regression for the 2026-08-06 body-swallowing bug: `draft`/`send` spawn
  # emate, and under the old `system(...)` spawn the child inherited the
  # process's REAL fd 0/1 — which in the stdio MCP server are the JSON-RPC
  # pipes. emate blocked reading the protocol stream and consumed the next
  # frame (a `notifications/cancelled` from a user-rejected tool call) as the
  # message body, while the composed body in the `$stdin` StringIO swap was
  # discarded. This drives the real `MCP.run` loop in a forked child whose
  # fd 0 IS the request pipe, exactly like production.
  def test_draft_body_reaches_emate_not_the_protocol_stream
    skip "fork unavailable" unless Process.respond_to?(:fork)
    Dir.mktmpdir do |dir|
      capture = File.join(dir, "capture.txt")
      fake = File.join(dir, "fake-emate")
      File.write(fake, <<~SH)
        #!/bin/sh
        { echo "ARGV: $*"; cat; } > "#{capture}"
      SH
      File.chmod(0o755, fake)

      req_rd, req_wr = IO.pipe
      res_rd, res_wr = IO.pipe
      pid = fork do
        req_wr.close
        res_rd.close
        STDIN.reopen(req_rd) # fd 0 is the JSON-RPC transport, as in production
        Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
        Mailmate::CLI::Send.const_set(:EMATE_PATH, fake)
        S.run(stdin: $stdin, stdout: res_wr)
        exit!(0) # skip minitest's at_exit autorun in the fork
      end
      req_rd.close
      res_wr.close

      send_frame = ->(h) { req_wr.write(JSON.generate(h) + "\n") }
      send_frame.call({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
      send_frame.call({ jsonrpc: "2.0", id: 2, method: "tools/call",
                        params: { name: "draft", arguments: {
                          "to" => "x@y.z", "subject" => "subj", "body" => "THE REAL COMPOSED BODY"
                        } } })
      # The frame a user-cancel appends mid-call; before the fix emate
      # swallowed this line as the message body.
      send_frame.call({ jsonrpc: "2.0", method: "notifications/cancelled",
                        params: { requestId: 2, reason: "AbortError: user-cancel" } })
      req_wr.close

      responses = res_rd.read.lines.map { |l| JSON.parse(l) }
      Process.waitpid(pid)

      captured = File.read(capture)
      assert_includes captured, "THE REAL COMPOSED BODY"
      refute_match(/jsonrpc|notifications/, captured)
      # The protocol stream stayed parseable line-per-line (no emate output
      # interleaved) and the draft call was answered.
      draft_response = responses.find { |r| r["id"] == 2 }
      refute_nil draft_response, "tools/call id=2 never answered"
      refute draft_response["result"]["isError"], "draft reported an error: #{draft_response}"
    end
  end

  # ---- parent-derived compose (reply_to / reply_all_to / forward) ----
  #
  # The MCP does NOT derive anything itself — it hands the parent id to the
  # CLI, which owns the one implementation. These assert the handoff and the
  # recipient guard that replaced the schema's `required: to`.

  def compose_argv(args)
    S.send(:compose_argv, args)
  end

  def test_reply_to_is_forwarded_to_the_cli
    argv = compose_argv({ "reply_to" => "<p@example.com>", "body" => "hi" })
    assert_includes argv.each_cons(2).to_a, ["--reply-to", "<p@example.com>"]
  end

  def test_reply_all_to_and_forward_map_to_their_own_flags
    assert_includes compose_argv({ "reply_all_to" => "42" }).each_cons(2).to_a, ["--reply-all-to", "42"]
    assert_includes compose_argv({ "forward" => "42" }).each_cons(2).to_a, ["--forward", "42"]
  end

  def test_explicit_fields_still_ship_alongside_a_parent
    pairs = compose_argv({ "reply_to" => "42", "to" => "other@example.com", "subject" => "Mine" }).each_cons(2).to_a
    assert_includes pairs, ["-t", "other@example.com"]
    assert_includes pairs, ["-s", "Mine"]
    assert_includes pairs, ["--reply-to", "42"]
  end

  def test_quote_false_suppresses_the_quoted_original
    assert_includes compose_argv({ "reply_to" => "42", "quote" => false }), "--no-quote"
    refute_includes compose_argv({ "reply_to" => "42" }), "--no-quote"
  end

  # Hand-set header values still route through the shared sanitizer, so a
  # parent Message-ID carrying CR/LF can't smuggle a second header.
  def test_hand_set_threading_headers_are_sanitized
    argv = compose_argv({ "in_reply_to" => "a@b\r\nBcc: attacker@example.com" })
    header = argv[argv.index("--header") + 1]
    refute_includes header, "\n"
    refute_includes header, "\r"
  end

  def test_a_call_with_no_recipient_and_no_parent_is_an_error
    res = S.send(:call_draft, { "subject" => "x", "body" => "y" })
    assert res[:isError], "expected isError for a recipient-less draft"
    assert_includes res[:content].first[:text], "no recipient"
  end

  def test_reply_to_satisfies_the_recipient_requirement
    assert_nil S.send(:recipient_check, { "reply_to" => "42", "body" => "y" })
  end

  # A forward derives subject and body but NOT a recipient — the whole point
  # is sending it to someone new, so `to` stays required there.
  def test_forward_without_a_recipient_is_an_error
    refute_nil S.send(:recipient_check, { "forward" => "42", "body" => "y" })
    assert_nil S.send(:recipient_check, { "forward" => "42", "to" => "new@example.com" })
  end
end

class TestMcpSearchLimitAndSort < Minitest::Test
  S = Mailmate::MCP

  def test_call_search_maps_limit_by_scan_limit_and_key_sorts_onto_the_cli
    seen = nil
    Mailmate::CLI::Search.stub(:run, ->(argv) { seen = argv; 0 }) do
      S.dispatch("search", "query" => "f bob", "limit" => 10, "limit_by" => "date:asc",
                           "scan_limit" => 500, "sort" => "from:desc")
    end
    assert_equal ["--limit", "10", "--limit-by", "date:asc", "--scan-limit", "500",
                  "--sort", "from:desc", "--stats", "f bob"], seen
  end

  def test_call_search_passes_the_truncation_notice_through_on_success
    fake = lambda do |_argv|
      puts "id,date\n1,2026-01-01"
      warn "[limit] showing 1 of 2 matches (newest first by date)"
      0
    end
    res = Mailmate::CLI::Search.stub(:run, fake) { S.dispatch("search", "query" => "x", "limit" => 1) }
    text = res[:content].first[:text]
    refute res[:isError]
    assert_includes text, "1,2026-01-01"
    assert_includes text, "[stderr]\n[limit] showing 1 of 2 matches"
  end

  def test_call_search_maps_offset_and_always_asks_for_stats
    seen = nil
    Mailmate::CLI::Search.stub(:run, ->(argv) { seen = argv; 0 }) do
      S.dispatch("search", "query" => "x", "limit" => 200, "offset" => 1000)
    end
    assert_equal ["--limit", "200", "--offset", "1000", "--stats", "x"], seen
  end

  def test_call_search_surfaces_the_stats_line_as_structured_content
    fake = lambda do |_argv|
      warn 'stats: {"schema":1,"matches":321,"returned":3,"scan_capped":false}'
      puts "id\n1"
      0
    end
    res = Mailmate::CLI::Search.stub(:run, fake) { S.dispatch("search", "query" => "x") }
    assert_equal 321, res[:structuredContent][:stats]["matches"]
    assert_includes res[:content].first[:text], "stats: {", "the line stays readable in the text too"
  end

  def test_call_search_leaves_a_malformed_stats_line_as_text
    fake = ->(_argv) { warn "stats: {not json"; puts "id\n1"; 0 }
    res = Mailmate::CLI::Search.stub(:run, fake) { S.dispatch("search", "query" => "x") }
    refute res.key?(:structuredContent)
    assert_includes res[:content].first[:text], "stats: {not json"
  end
end
