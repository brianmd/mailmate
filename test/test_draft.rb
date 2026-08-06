# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/draft"

class TestDraft < Minitest::Test
  include Mailmate::TestHelpers

  def test_refuses_send_now
    actual = nil
    out, err = capture_subprocess_io { actual = Mailmate::CLI::Draft.run(["-t", "x@y.z", "--send-now"]) }
    assert_equal 2, actual
    assert_match(/refusing --send-now/, err)
    # Never reaches emate, so no send-side output.
    assert_empty out
  end

  def test_delegates_to_send_without_send_now
    # Stub EMATE_PATH to /usr/bin/true so the delegated Send.run exits 0.
    orig = Mailmate::CLI::Send::EMATE_PATH
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, "/usr/bin/true")

    actual = nil
    with_stdin("") { capture_subprocess_io { actual = Mailmate::CLI::Draft.run(["-t", "x@y.z"]) } }
    assert_equal 0, actual
  ensure
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, orig)
  end
end
