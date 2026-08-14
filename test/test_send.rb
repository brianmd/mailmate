# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/send"
require "tmpdir"

class TestSend < Minitest::Test
  include Mailmate::TestHelpers

  # Point EMATE_PATH at `path` for the duration of the block.
  def with_emate(path)
    orig = Mailmate::CLI::Send::EMATE_PATH
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, path)
    yield
  ensure
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, orig)
  end

  # A fake emate that records its argv and stdin to `capture` and prints
  # canned output on both streams, so tests can observe exactly what the
  # child received and where its output went.
  def write_fake_emate(dir, capture)
    fake = File.join(dir, "fake-emate")
    File.write(fake, <<~SH)
      #!/bin/sh
      { echo "ARGV: $*"; echo "--- STDIN ---"; cat; } > "#{capture}"
      echo "emate-stdout-marker"
      echo "emate-stderr-marker" >&2
    SH
    File.chmod(0o755, fake)
    fake
  end

  def test_run_returns_exit_code_when_emate_missing
    actual = nil
    with_emate("/nonexistent/emate") do
      capture_subprocess_io { actual = Mailmate::CLI::Send.run(["--to", "x@y.z"]) }
    end
    assert_equal 1, actual
  end

  def test_run_returns_integer_when_emate_present
    actual = nil
    with_emate("/usr/bin/true") do
      # `true` ignores its args and exits 0. The point is that run() returns
      # an Integer instead of replacing the process.
      with_stdin("") { capture_subprocess_io { actual = Mailmate::CLI::Send.run([]) } }
    end
    assert_kind_of Integer, actual
    assert_equal 0, actual
  end

  # ---- fd hygiene: the MCP body-swallowing bug (2026-08-06) ----

  def test_body_reaches_emate_on_a_private_pipe_not_inherited_fd0
    Dir.mktmpdir do |dir|
      capture = File.join(dir, "capture.txt")
      fake = write_fake_emate(dir, capture)
      actual = nil
      with_emate(fake) do
        # $stdin is a StringIO — exactly the MCP server's with_stdin swap.
        # Under the old system() spawn the child could not see it and read
        # the process's real fd 0 instead.
        with_stdin("THE REAL COMPOSED BODY") do
          capture_subprocess_io { actual = Mailmate::CLI::Send.run(["-t", "x@y.z", "-s", "subj"]) }
        end
      end
      assert_equal 0, actual
      captured = File.read(capture)
      assert_includes captured, "ARGV: mailto --markup markdown -t x@y.z -s subj"
      assert_includes captured, "THE REAL COMPOSED BODY"
    end
  end

  def test_emate_output_is_reemitted_through_ruby_globals
    Dir.mktmpdir do |dir|
      fake = write_fake_emate(dir, File.join(dir, "capture.txt"))
      out_io = StringIO.new
      err_io = StringIO.new
      old_out, old_err = $stdout, $stderr
      begin
        $stdout, $stderr = out_io, err_io
        with_emate(fake) do
          with_stdin("body") { Mailmate::CLI::Send.run(["-t", "x@y.z"]) }
        end
      ensure
        $stdout, $stderr = old_out, old_err
      end
      # Captured via the globals (what the MCP's with_captured_io swaps), not
      # written to the process's real fd 1/2 — which in the MCP server is the
      # JSON-RPC transport.
      assert_includes out_io.string, "emate-stdout-marker"
      assert_includes err_io.string, "emate-stderr-marker"
    end
  end

  def test_help_does_not_consume_stdin
    Dir.mktmpdir do |dir|
      fake = write_fake_emate(dir, File.join(dir, "capture.txt"))
      stdin_io = StringIO.new("should stay unread")
      old = $stdin
      begin
        $stdin = stdin_io
        with_emate(fake) { capture_subprocess_io { Mailmate::CLI::Send.run(["--help"]) } }
      ensure
        $stdin = old
      end
      # An interactive `mm-send --help` must not hang waiting for Ctrl-D.
      assert_equal 0, stdin_io.pos
    end
  end

  # ---- --reply-to / --reply-all-to / --forward ----
  #
  # The derivation itself is covered in test_reply_prefill.rb; these assert
  # the CLI contract on top of it — what lands in emate's argv, and that the
  # merge rule ("explicit wins, omitted follows reply rules") holds.

  # Stub the derivation so these tests exercise argv assembly only, with no
  # dependence on a resolvable message.
  def with_prefill(prefill)
    orig = Mailmate::ReplyPrefill.method(:build)
    Mailmate::ReplyPrefill.define_singleton_method(:build) { |_id, **_kw| prefill }
    yield
  ensure
    Mailmate::ReplyPrefill.define_singleton_method(:build, orig)
  end

  def sample_prefill(**over)
    Mailmate::ReplyPrefill::Prefill.new(**{
      mode: "reply", from: "me@example.com", to: ["parent@example.com"], cc: [],
      subject: "Re: Closet flickering", in_reply_to: "<parent@example.com>",
      references: "<root@example.com> <parent@example.com>",
      quoted_body: "On Tue, someone wrote:\n> it flickers\n",
      parent_message_id: "<parent@example.com>", parent_eml_id: 42
    }.merge(over))
  end

  # Run Send.run against a fake emate and return everything it captured.
  def captured_argv(argv, body: "Body", prefill: nil)
    prefill ||= sample_prefill
    Dir.mktmpdir do |dir|
      capture = File.join(dir, "capture.txt")
      fake = write_fake_emate(dir, capture)
      with_emate(fake) do
        with_prefill(prefill) do
          with_stdin(body) { capture_subprocess_io { Mailmate::CLI::Send.run(argv) } }
        end
      end
      return File.read(capture)
    end
  end

  def test_reply_to_splices_recipient_subject_and_threading_headers
    out = captured_argv(["--reply-to", "<parent@example.com>"])
    assert_includes out, "-t parent@example.com"
    assert_includes out, "-s Re: Closet flickering"
    assert_includes out, "--header In-Reply-To: <parent@example.com>"
    assert_includes out, "--header References: <root@example.com> <parent@example.com>"
    # Our own flag never reaches emate, which knows nothing about it.
    refute_includes out, "--reply-to"
  end

  def test_explicitly_passed_fields_win_over_derived_ones
    out = captured_argv(["-t", "someone@example.com", "-s", "My subject", "--reply-to", "<p@example.com>"])
    assert_includes out, "-t someone@example.com"
    assert_includes out, "-s My subject"
    refute_includes out, "-t parent@example.com"
    refute_includes out, "Re: Closet flickering"
  end

  # The whole point of the feature: overriding a visible field must not
  # quietly drop the invisible headers that make it a reply.
  def test_overriding_recipients_does_not_drop_the_threading_headers
    out = captured_argv(["-t", "someone@example.com", "--reply-to", "<p@example.com>"])
    assert_includes out, "--header In-Reply-To: <parent@example.com>"
  end

  def test_a_hand_set_threading_header_is_not_duplicated
    out = captured_argv(["--header", "In-Reply-To: <mine@example.com>", "--reply-to", "<p@example.com>"])
    assert_includes out, "--header In-Reply-To: <mine@example.com>"
    refute_includes out, "In-Reply-To: <parent@example.com>"
    # References wasn't hand-set, so ours still applies.
    assert_includes out, "--header References: <root@example.com> <parent@example.com>"
  end

  def test_the_quoted_original_is_appended_below_the_caller_body
    out = captured_argv(["--reply-to", "<p@example.com>"], body: "On it.")
    body = out.split("--- STDIN ---").last
    assert_match(/On it\.\s+On Tue, someone wrote:/m, body)
    assert_includes body, "> it flickers"
  end

  def test_no_quote_suppresses_the_quoted_original
    out = captured_argv(["--reply-to", "<p@example.com>", "--no-quote"], body: "On it.")
    body = out.split("--- STDIN ---").last
    refute_includes body, "it flickers"
    refute_includes out, "--no-quote"
  end

  def test_reply_all_passes_the_mode_through_to_the_derivation
    seen = nil
    prefill = sample_prefill
    orig = Mailmate::ReplyPrefill.method(:build)
    Mailmate::ReplyPrefill.define_singleton_method(:build) do |_id, **kw|
      seen = kw[:mode]
      prefill
    end
    begin
      Dir.mktmpdir do |dir|
        fake = write_fake_emate(dir, File.join(dir, "capture.txt"))
        with_emate(fake) { with_stdin("b") { capture_subprocess_io { Mailmate::CLI::Send.run(["--reply-all-to", "1"]) } } }
      end
    ensure
      Mailmate::ReplyPrefill.define_singleton_method(:build, orig)
    end
    assert_equal "reply-all", seen
  end

  def test_forward_carries_no_threading_headers
    fwd = sample_prefill(mode: "forward", to: [], in_reply_to: nil, references: nil, subject: "Fwd: Closet flickering")
    out = captured_argv(["--forward", "1", "-t", "new@example.com"], prefill: fwd)
    assert_includes out, "-t new@example.com"
    assert_includes out, "-s Fwd: Closet flickering"
    refute_includes out, "In-Reply-To"
    refute_includes out, "References"
  end

  # --print-prefill is a QUERY: it must answer without a launchable MailMate,
  # because markdownr calls it to fill a form on a machine where emate may be
  # missing or the app not running.
  def test_print_prefill_emits_json_and_never_execs_emate
    require "json"
    out_io = StringIO.new
    old_out = $stdout
    status = nil
    begin
      $stdout = out_io
      with_emate("/nonexistent/emate") do
        with_prefill(sample_prefill) { status = Mailmate::CLI::Send.run(["--reply-to", "1", "--print-prefill"]) }
      end
    ensure
      $stdout = old_out
    end
    assert_equal 0, status
    parsed = JSON.parse(out_io.string)
    assert_equal "<parent@example.com>", parsed["in_reply_to"]
    assert_equal "<root@example.com> <parent@example.com>", parsed["references"]
    assert_equal ["parent@example.com"], parsed["to"]
  end

  def test_print_prefill_without_a_parent_is_an_error
    status = nil
    capture_subprocess_io { status = Mailmate::CLI::Send.run(["--print-prefill"]) }
    assert_equal 1, status
  end

  def test_two_parent_flags_is_an_error
    status = nil
    capture_subprocess_io { status = Mailmate::CLI::Send.run(["--reply-to", "1", "--forward", "2"]) }
    assert_equal 1, status
  end

  def test_parent_flag_without_a_value_is_an_error
    status = nil
    capture_subprocess_io { status = Mailmate::CLI::Send.run(["--reply-to"]) }
    assert_equal 1, status
  end
end
