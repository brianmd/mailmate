# frozen_string_literal: true

require "uri"

module Mailmate
  # @api public
  #
  # Map an `.eml` body-part ID to its absolute on-disk path.
  #
  # Two implementations:
  #   - The fast path uses MailMate's `#source` index
  #     (`Database.noindex/Headers/#source.{cache,offsets}`), which carries the
  #     `imap://account@host/path` URL for every indexed message. O(1) lookup.
  #   - The fallback walks the IMAP tree with `Dir.glob`, the same shape as the
  #     `find -name <id>.eml` shell-out the original scripts used. Slower
  #     (seconds on a cold cache) but always works.
  #
  # The fast path wins ~99% of the time. The fallback exists for messages
  # MailMate hasn't yet indexed (e.g. immediately after a fresh IMAP push) and
  # for edge cases where `#source` is unreadable.
  module EmlLookup
    # Returns an absolute path string, or nil if not found.
    def self.path_for(eml_id)
      via_index(eml_id) || via_glob(eml_id)
    end

    # Reverse-lookup: given an RFC Message-ID (with or without angle brackets),
    # return the local eml-id (integer) or nil. Backed by a value→id map built
    # once per index snapshot (one O(n) pass, then O(1) lookups) — the map is
    # pinned to the IndexReader object it was built from, so when the index
    # rebuilds (file changed on disk) the map rebuilds with it. Matters for
    # the persistent MCP server, where resolve_id is called repeatedly.
    def self.eml_id_for_message_id(message_id)
      needle = message_id.to_s.strip
      return nil if needle.empty?

      candidates = needle.start_with?("<") && needle.end_with?(">") ?
                     [needle, needle[1..-2]] :
                     [needle, "<#{needle}>"]

      map = mid_map
      candidates.each do |c|
        id = map[c]
        return id if id
      end
      nil
    rescue ArgumentError
      nil
    end

    # value→eml-id map over the message-id index. `||=` keeps the FIRST id
    # recorded for a duplicated Message-ID, matching the old scan's
    # first-match-wins semantics (duplicates are real: Sent + Received
    # copies, Gmail label copies).
    def self.mid_map
      reader = Mailmate::IndexReader.for("message-id")
      return @mid_map[:map] if @mid_map && @mid_map[:reader].equal?(reader)
      map = {}
      reader.each_record { |eml_id, value| map[value] ||= eml_id }
      @mid_map = { reader: reader, map: map }
      map
    end

    # Resolve an identifier to a local eml-id. Accepts:
    #   - eml-id (all digits)              e.g. "183715"
    #   - RFC Message-ID, brackets optional e.g. "<abc@example.com>"
    #   - message://… URL                  e.g. "message://%3Cabc%40example.com%3E"
    #                                           or "message://183715"
    #   - mid:… URL                        e.g. "mid:%3Cabc%40example.com%3E"
    #                                           or "mid:183715"
    # Strips the URL wrapper first (message:// or mid:) so the digit check
    # below catches the local-eml-id payload too — same leniency MailMate's
    # own URL handler offers. The %3C…%3E payload form is portable across
    # machines; the bare-integer form is local-only.
    def self.resolve_id(input)
      s = input.to_s.strip
      s = URI.decode_www_form_component(s.sub(%r{\A(?:message://|mid:)}, "")) if s.match?(%r{\A(?:message://|mid:)})
      return s.to_i if s =~ /\A\d+\z/
      eml_id_for_message_id(s)
    end

    # Force the index path (useful for tests and benchmarking).
    #
    # Returns nil — not just on missing-index — when the indexed path no
    # longer points at an existing file. That happens whenever MailMate's
    # `#source` index lags the filesystem; the common case is right after
    # `mm-modify`'s fast-path move renames the .eml on disk and MailMate
    # hasn't rescanned yet. Treating stale entries as misses lets `path_for`
    # fall through to the glob walker and recover the file at its new home.
    def self.via_index(eml_id)
      url = source_url_for(eml_id)
      return nil if url.nil?
      path = url_to_path(url, eml_id)
      path if path && File.exist?(path)
    end

    # Force the glob fallback.
    def self.via_glob(eml_id)
      matches = Dir.glob("#{Mailmate.config.imap_root}/*/**/Messages/#{eml_id}.eml")
      matches.first
    end

    # Lookup the `imap://...` URL recorded in `#source` for this eml_id.
    # Returns nil if the index doesn't have a record for it.
    def self.source_url_for(eml_id)
      Mailmate::IndexReader.for("#source").value_for(eml_id)
    rescue ArgumentError
      # #source index missing (non-default MailMate install? fresh sync?).
      nil
    end

    # Convert an `imap://account@host/mailbox/path` URL to the on-disk
    # absolute path of the .eml file. Internal but exposed for tests.
    def self.url_to_path(url, eml_id)
      stripped = url.sub(%r{\Aimap://}, "")
      account, mailbox_path = stripped.split("/", 2)
      return nil if account.nil? || mailbox_path.nil? || mailbox_path.empty?

      mailbox_dirs = mailbox_path.split("/").map { |seg| "#{seg}.mailbox" }.join("/")
      File.join(Mailmate.config.imap_root, account, mailbox_dirs, "Messages", "#{eml_id}.eml")
    end
  end
end
