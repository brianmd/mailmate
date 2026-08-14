# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # Sanitize a value destined for an `emate --header "Name: value"` flag.
  #
  # Header values ship VERBATIM into the outgoing message, and the values we
  # inject most often (`In-Reply-To`, `References`) are derived from ANOTHER
  # message — i.e. from input nobody in this process authored. A value
  # carrying CR/LF would end the header and begin a new one, smuggling
  # arbitrary RFC 5322 headers (a `Bcc:`, say) into mail the caller believes
  # they fully specified.
  #
  # Every path that builds a `--header` flag must run its value through here.
  # There is deliberately ONE implementation: this logic previously existed in
  # two places (the MCP server's argv builder and markdownr's), and only one of
  # them had the defense — which is exactly the failure mode a shared helper
  # exists to prevent.
  module HeaderValue
    extend self

    # Collapse any CR/LF (and the whitespace that follows it, so an unfolded
    # continuation doesn't leave a ragged double space) to a single space,
    # then trim. Returns a String; nil/empty in → "" out.
    def sanitize(value)
      value.to_s.gsub(/[\r\n]+\s*/, " ").strip
    end

    # Wrap a Message-ID in angle brackets unless it already has them. Both
    # forms are valid input; the on-wire form is bracketed per RFC 5322.
    # Sanitizes first, so a smuggled newline can't survive by hiding inside
    # what looks like an already-bracketed id.
    def bracket_message_id(id)
      s = sanitize(id)
      return s if s.empty?
      return s if s.start_with?("<") && s.end_with?(">")

      "<#{s}>"
    end
  end
end
