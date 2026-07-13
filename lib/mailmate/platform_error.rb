# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # Raised when a subsystem that needs macOS-specific bits (AppleScript,
  # MailMate's on-disk layout, the `open` and `osascript` commands) is invoked
  # on a non-macOS host. Library-only code paths (parser, evaluator over
  # synthetic fixtures) keep working anywhere; this error only surfaces at
  # actual integration points.
  class PlatformError < StandardError
    def self.check_darwin!(component:)
      return if RUBY_PLATFORM.include?("darwin")
      raise new(
        "#{component} requires macOS (RUBY_PLATFORM=#{RUBY_PLATFORM}). " \
        "The mailmate gem's library code (filter parser, evaluator) works " \
        "on any platform, but integration with MailMate itself is macOS-only.",
      )
    end
  end
end
