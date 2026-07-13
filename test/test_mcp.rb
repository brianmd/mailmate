# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/mcp"

# Tests for the in-process MCP dispatch layer. The transport (stdio JSON-RPC
# loop) is exercised end-to-end elsewhere; here we pin the two behaviors that
# protect the persistent server: dispatch never lets an in-process CLI crash
# the loop, and argv synthesis threads the documented options through.
class TestMCP < Minitest::Test
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
end
