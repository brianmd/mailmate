# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class TestAppleScriptDriver < Minitest::Test
  include Mailmate::TestHelpers

  # ---- Script construction (pure logic) ----

  def test_build_no_args
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    script = driver.build_perform_script("markAsRead:", [])
    assert_equal %(tell application "MailMate" to perform {"markAsRead:"}), script
  end

  def test_build_with_one_arg
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    script = driver.build_perform_script("setTag:", ["urgent"])
    assert_equal %(tell application "MailMate" to perform {"setTag:", "urgent"}), script
  end

  def test_build_with_multiple_args
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    script = driver.build_perform_script("foo:", %w[a b c])
    assert_equal %(tell application "MailMate" to perform {"foo:", "a", "b", "c"}), script
  end

  def test_build_escapes_double_quotes_in_args
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    script = driver.build_perform_script("setTag:", ['has "quotes"'])
    assert_includes script, '\\"quotes\\"'
  end

  def test_build_escapes_backslash_in_args
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    script = driver.build_perform_script("setTag:", ['foo\\bar'])
    # Single backslash in the input must appear as a double backslash inside
    # the AppleScript string literal, so AppleScript reads the value as a
    # single backslash.
    assert_includes script, 'foo\\\\bar'
    refute_match(/foo\\bar(?!\\)/, script)
  end

  def test_build_escapes_backslash_before_quote
    # Tricky order-of-operations case: "foo\"" must become "foo\\\""
    # (one literal backslash + one literal quote inside the AppleScript string).
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    script = driver.build_perform_script("setTag:", ['foo\\"'])
    assert_includes script, 'foo\\\\\\"'
  end

  def test_rejects_control_characters_in_args
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    assert_raises(Mailmate::AppleScriptDriver::Error) do
      driver.build_perform_script("setTag:", ["has\nnewline"])
    end
    assert_raises(Mailmate::AppleScriptDriver::Error) do
      driver.build_perform_script("setTag:", ["has\ttab"])
    end
  end

  # ---- Dry-run behavior ----

  def test_perform_in_dry_run_prints_script_and_does_not_invoke
    output = StringIO.new
    driver = Mailmate::AppleScriptDriver.new(dry_run: true, output: output)
    driver.perform("markAsRead:")
    assert_includes output.string, "DRY:"
    assert_includes output.string, "markAsRead:"
  end

  def test_open_url_in_dry_run
    output = StringIO.new
    driver = Mailmate::AppleScriptDriver.new(dry_run: true, output: output)
    driver.open_url("mid:%3Cabc%3E")
    assert_includes output.string, "DRY:"
    assert_includes output.string, "mid:"
  end

  def test_window_ids_in_dry_run_returns_empty
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    assert_equal [], driver.window_ids
  end

  def test_close_windows_in_dry_run_is_a_noop
    driver = Mailmate::AppleScriptDriver.new(dry_run: true)
    # Should not raise; should not invoke osascript.
    driver.close_windows([42, 99])
  end

  # ---- Sanity: real invocation path is wired (don't actually call) ----

  def test_perform_skips_darwin_check_in_dry_run
    # On non-darwin hosts, perform() outside dry_run would raise PlatformError.
    # In dry_run, it should not — the actual integration is mocked out.
    driver = Mailmate::AppleScriptDriver.new(dry_run: true, output: StringIO.new)
    driver.perform("markAsRead:")
  end
end
