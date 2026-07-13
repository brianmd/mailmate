# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # Build URLs that point to a single MailMate message:
  #
  #   - `mid:%3C<id>%3E`       — local MailMate driver URL (RFC 2392). Selects
  #                              the message in the local store; what
  #                              `mm-modify` uses to drive the UI.
  #   - `message://%3C<id>%3E` — portable, cross-machine reference. Same
  #                              encoding, different scheme. Resolves to the
  #                              same physical email on any MailMate install
  #                              because the RFC `Message-ID` header is
  #                              globally unique.
  #
  # Both schemes need the angle brackets that wrap a Message-ID to be
  # percent-encoded; characters that would break URL parsers (`[`, `]`,
  # whitespace) are also encoded. Other URL-reserved characters (`@`, `.`,
  # `-`, `_`) are preserved — MailMate's parser accepts them as-is.
  module MidUrl
    # `mid:%3C<message-id>%3E` — used by MailMate to select a message locally.
    def self.for(message_id)
      "mid:#{encoded_with_brackets(message_id)}"
    end

    # `message://%3C<message-id>%3E` — portable cross-machine reference. Pass
    # back to `EmlLookup.resolve_id` (or any CLI that takes an id) to look up
    # the same physical email on another machine.
    def self.message_url_for(message_id)
      "message://#{encoded_with_brackets(message_id)}"
    end

    # Percent-encoded `%3C…%3E` envelope shared by both schemes. Exposed in
    # case a caller wants the brackets-only form without a scheme prefix.
    def self.encoded_with_brackets(message_id)
      raise ArgumentError, "Message-ID required" if message_id.nil? || message_id.to_s.empty?
      id = message_id.to_s.sub(/\A</, "").sub(/>\z/, "")
      encoded = id.gsub(/[\[\]<>\s]/) { |c| "%%%02X" % c.ord }
      "%3C#{encoded}%3E"
    end
  end
end
