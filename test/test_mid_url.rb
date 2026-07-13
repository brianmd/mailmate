# frozen_string_literal: true

require_relative "test_helper"

class TestMidUrl < Minitest::Test
  include Mailmate::TestHelpers

  def test_builds_basic_url
    assert_equal "mid:%3Cabc123@example.com%3E", Mailmate::MidUrl.for("abc123@example.com")
  end

  def test_strips_angle_brackets
    assert_equal "mid:%3Cabc123@example.com%3E", Mailmate::MidUrl.for("<abc123@example.com>")
  end

  def test_handles_complex_message_ids
    id = "DEADBEEF-0000-4000-8000-000000000000@mail.example.com"
    assert_equal "mid:%3C#{id}%3E", Mailmate::MidUrl.for(id)
  end

  def test_raises_on_empty
    assert_raises(ArgumentError) { Mailmate::MidUrl.for("") }
    assert_raises(ArgumentError) { Mailmate::MidUrl.for(nil) }
  end
end
