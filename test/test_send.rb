# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/send"

class TestSend < Minitest::Test
  include Mailmate::TestHelpers

  def test_run_returns_exit_code_when_emate_missing
    # Temporarily replace EMATE_PATH with a path that doesn't exist.
    orig = Mailmate::CLI::Send::EMATE_PATH
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, "/nonexistent/emate")

    code = capture_subprocess_io { Mailmate::CLI::Send.run(["--to", "x@y.z"]) }
    # The actual return value lives in run's return — capture it directly.
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, "/nonexistent/emate")
    actual = nil
    capture_subprocess_io { actual = Mailmate::CLI::Send.run(["--to", "x@y.z"]) }
    assert_equal 1, actual
  ensure
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, orig)
  end

  def test_run_returns_integer_when_emate_present
    # Stub EMATE_PATH to point at /usr/bin/true (always exits 0).
    orig = Mailmate::CLI::Send::EMATE_PATH
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, "/usr/bin/true")

    actual = nil
    capture_subprocess_io { actual = Mailmate::CLI::Send.run([]) }
    # `true` ignores its args and exits 0. The point is that run() returns
    # an Integer instead of replacing the process.
    assert_kind_of Integer, actual
    assert_equal 0, actual
  ensure
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, orig)
  end
end
