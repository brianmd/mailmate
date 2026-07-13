# frozen_string_literal: true

require_relative "../test_helper"

module Mailmate
  module LiveTestHelpers
    # Skip the test block when MailMate isn't installed / configured on this
    # host. Live tests are opt-in via `rake test:live` and self-skip otherwise.
    def require_live_mailmate
      unless File.directory?(Mailmate.config.app_support_dir)
        skip "MailMate app-support dir not found at #{Mailmate.config.app_support_dir}"
      end
    end
  end
end
