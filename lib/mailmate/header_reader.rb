# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # Read just the header block of an `.eml` file. Pulls in a small amount of
  # the file from disk (up to ~64 KB), stops at the first blank line that
  # separates headers from body, and extracts named header values.
  #
  # Cheap relative to `Mail.read` — no MIME parsing, no body decode — when all
  # the caller wants is `Message-ID` or `From` from a known `.eml` path.
  #
  # Stateless utility surface, so it's a module (cf. AppleScriptDriver, which
  # is a class because it carries per-invocation state).
  module HeaderReader
    extend self

    DEFAULT_MAX_BYTES = 65_536
    CHUNK_SIZE        = 4_096

    # Returns the raw bytes of the header block, capped at `max_bytes`.
    # Truncates at the first blank line (the header/body separator) so callers
    # looking for "To:" or similar don't accidentally match a `To:` line that
    # appears in the body.
    def read_block(path, max_bytes: DEFAULT_MAX_BYTES)
      header_bytes = +""
      File.open(path, "rb") do |f|
        while (chunk = f.read(CHUNK_SIZE))
          header_bytes << chunk
          break if header_bytes.index("\r\n\r\n") || header_bytes.index("\n\n")
          break if header_bytes.bytesize > max_bytes
        end
      end

      if (i = header_bytes.index("\r\n\r\n"))
        header_bytes[0, i]
      elsif (i = header_bytes.index("\n\n"))
        header_bytes[0, i]
      else
        header_bytes
      end
    end

    # Extract a named header's value from a path. Case-insensitive. Handles
    # RFC 5322 §2.2.3 header folding — a value continued on subsequent lines
    # with leading whitespace is unfolded into a single line (CRLF + WSP
    # collapsed to a single space). Returns nil if the header isn't present
    # in the first `max_bytes` of the file.
    def header(path, name, max_bytes: DEFAULT_MAX_BYTES)
      block = read_block(path, max_bytes: max_bytes)
      # Match the header name at start of line, then the rest of that line and
      # any subsequent continuation lines (lines beginning with WSP).
      pattern = /^#{Regexp.escape(name)}:[\t ]*(.*(?:\r?\n[\t ].*)*)/i
      match = block.match(pattern)
      return nil unless match
      unfold(match[1])
    end

    # Collapse CRLF + WSP runs into a single space (RFC 5322 §2.2.3
    # "unfolding"). Trailing whitespace is stripped.
    def unfold(raw)
      raw.gsub(/\r?\n[\t ]+/, " ").strip
    end

    # Convenience for the Message-ID specifically. Strips the surrounding angle
    # brackets if present, returning the bare ID suitable for building a
    # `mid:` URL via Mailmate::MidUrl.for.
    def message_id(path)
      val = header(path, "Message-ID")
      return nil if val.nil?
      val.match(/<([^>]+)>/)&.captures&.first || val
    end
  end
end
