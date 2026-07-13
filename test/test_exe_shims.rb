# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# End-to-end smoke tests for the exe/ shims. Each shim is spawned with
# --help (or a known-good no-op argv) and we assert the exit shape and
# basic stdout content. Catches "shim wires up the wrong CLI class" and
# LOAD_PATH regressions.
class TestExeShims < Minitest::Test
  include Mailmate::TestHelpers

  EXE_DIR = File.expand_path("../exe", __dir__)

  def shim(name)
    File.join(EXE_DIR, name)
  end

  # OptionParser raises SystemExit(0) on --help by default. Spawning a fresh
  # process lets us observe the exit code without polluting the test runner.
  # Use the same Ruby that's running the test.
  def spawn_shim(name, *args)
    Open3.capture3(RbConfig.ruby, shim(name), *args)
  end

  # ---- existence + permissions ----

  def test_core_shims_present_and_executable
    %w[mmsearch mmmessage mm-modify mm-verify mm-send mmdiscover].each do |name|
      path = shim(name)
      assert File.exist?(path), "missing exe/#{name}"
      assert File.executable?(path), "not executable: exe/#{name}"
    end
  end

  # ---- mmsearch ----

  def test_mmsearch_help_succeeds
    stdout, _stderr, status = spawn_shim("mmsearch", "--help")
    assert status.success?
    assert_match(/Usage:.*mmsearch/, stdout)
  end

  # ---- mmmessage ----

  def test_mmmessage_no_args_exits_with_usage_error
    _stdout, stderr, status = spawn_shim("mmmessage")
    refute status.success?
    assert_match(/usage|missing/i, stderr)
  end

  def test_mmmessage_unresolvable_id_exits_nonzero
    # A non-digit, non-resolvable input is treated as a candidate Message-ID
    # and looked up in the message-id index. No match → "Not found", exit 1.
    # (Pre-2026-05-13 behavior was an "invalid" usage error; the new behavior
    # accepts either eml-id or Message-ID so non-digit input is no longer a
    # syntax error.)
    _stdout, stderr, status = spawn_shim("mmmessage", "not-digits")
    refute status.success?
    assert_match(/not found|usage|missing/i, stderr)
  end

  # ---- mm-modify ----

  def test_mm_modify_help_succeeds
    stdout, _stderr, status = spawn_shim("mm-modify", "--help")
    assert status.success?
    assert_match(/Usage:.*mm-modify/, stdout)
  end

  def test_mm_modify_no_args_exits_with_usage_error
    _stdout, stderr, status = spawn_shim("mm-modify")
    refute status.success?
    assert_match(/usage|missing/i, stderr)
  end

  def test_mm_verify_help_succeeds
    stdout, _stderr, status = spawn_shim("mm-verify", "--help")
    assert status.success?
    assert_match(/Usage:.*mm-verify/, stdout)
  end

  def test_mm_verify_confirms_empty_expectations_ticket
    # A ticket with no expectations (e.g. a move) auto-passes without touching
    # MailMate — exercises the shim end-to-end with deterministic input.
    ticket = '{"eml_id":1,"message_id":"<a@b>","expectations":[]}'
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, shim("mm-verify"), stdin_data: ticket)
    assert status.success?, "all-pass batch should exit 0"
    assert_match(/"passed":\s*1/, stdout)
    assert_match(/"failed":\s*0/, stdout)
  end

  # ---- mmdiscover ----

  def test_mmdiscover_help_succeeds
    stdout, _stderr, status = spawn_shim("mmdiscover", "--help")
    assert status.success?
    assert_match(/Usage:.*mmdiscover/, stdout)
  end

  # ---- mm-send: best-effort (depends on macOS emate binary being present) ----

  def test_mm_send_exists
    assert File.exist?(shim("mm-send"))
  end
end
