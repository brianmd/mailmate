# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # "Is this address one of mine?" — answered against the identity list
  # configured at `Mailmate.config.identities`. Personal data lives in user
  # config (YAML or env vars), never in the gem source. This is the
  # canonical public surface; `Mailmate::Config` is data-only.
  module Identity
    extend self

    # Returns true if `address` matches any configured identity
    # (case-insensitive, whitespace-trimmed). Returns false for nil / empty
    # input, and false when no identities are configured — the "I don't know
    # who you are yet" state, deliberately safe rather than surprising.
    def mine?(address)
      return false if address.nil? || address.to_s.empty?
      addr = address.to_s.downcase.strip
      list.include?(addr)
    end

    # The configured identity list, as an array of lowercase strings.
    def list
      Mailmate.config.identities.map { |a| a.to_s.downcase.strip }
    end

    # Reject "my" addresses from an array. Useful for "who's the other party
    # in this conversation?" — pass the To/Cc/Bcc list, get back just the
    # external addresses.
    def reject_mine(addresses)
      Array(addresses).reject { |a| mine?(a.to_s) }
    end
  end
end
