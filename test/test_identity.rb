# frozen_string_literal: true

require_relative "test_helper"

class TestIdentity < Minitest::Test
  include Mailmate::TestHelpers

  def test_mine_with_configured_identities
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com,me@example.org" }) do
      assert Mailmate::Identity.mine?("me@example.com")
      assert Mailmate::Identity.mine?("ME@EXAMPLE.COM"), "case-insensitive"
      refute Mailmate::Identity.mine?("stranger@example.com")
    end
  end

  def test_mine_with_no_identities_returns_false
    with_config(env: {}) do
      refute Mailmate::Identity.mine?("anyone@example.com")
    end
  end

  def test_list_returns_lowercased_identities
    with_config(env: { "MAILMATE_IDENTITIES" => "Me@Example.Com,Other@Example.Org" }) do
      assert_equal ["me@example.com", "other@example.org"], Mailmate::Identity.list
    end
  end

  def test_reject_mine_filters_array
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com" }) do
      input = ["me@example.com", "friend@example.com", "ME@EXAMPLE.COM"]
      assert_equal ["friend@example.com"], Mailmate::Identity.reject_mine(input)
    end
  end

  def test_reject_mine_handles_empty_input
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com" }) do
      assert_equal [], Mailmate::Identity.reject_mine([])
      assert_equal [], Mailmate::Identity.reject_mine(nil)
    end
  end
end
