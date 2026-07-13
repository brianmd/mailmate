# frozen_string_literal: true

require_relative "test_helper_live"

# Identity recognition against the user's configured identities (loaded from
# ~/.config/mailmate/config.yml). Each address in Mailmate.config.identities
# must be mine; a known-synthetic non-identity must not be.
class TestLiveIdentity < Minitest::Test
  include Mailmate::TestHelpers
  include Mailmate::LiveTestHelpers

  def setup
    require_live_mailmate
  end

  def test_each_configured_identity_is_recognized
    ids = Mailmate.config.identities
    skip "no identities in config" if ids.empty?

    ids.each do |addr|
      assert Mailmate::Identity.mine?(addr), "should be mine: #{addr}"
    end
  end

  def test_synthetic_non_identity_is_not_mine
    refute Mailmate::Identity.mine?("definitely-not-mine-#{rand(1_000_000)}@example.invalid")
  end
end
