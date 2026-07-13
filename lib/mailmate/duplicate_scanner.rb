# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # Detect duplicate Message-ID copies across MailMate's tree. The same RFC
  # Message-ID can appear in multiple `.eml` files — Gmail's label-creates-a-copy
  # semantics produce this for any message that hits a labeled mailbox, and
  # self-to-self messages can end up in both Sent and INBOX folders.
  #
  # Why this matters: MailMate's `mid:` URL resolves to a single message
  # non-deterministically, so an action keyed by Message-ID can land on a
  # different `.eml` file than the one the user typed. `mailmate-modify` warns
  # when this is the case.
  #
  # Implementation uses MailMate's own `message-id` index — O(n) over the
  # decoded index instead of a recursive `grep -rli` over the whole IMAP tree.
  # [[Mailmate scripts speed]] §1.
  module DuplicateScanner
    # Returns Array<Integer> of eml-ids that share `message_id`. The array is
    # ordered as `#message-id` records them; callers don't depend on the order.
    def self.eml_ids_for(message_id)
      return [] if message_id.nil? || message_id.empty?

      reader = Mailmate::IndexReader.for("message-id")
      target = strip_brackets(message_id).downcase

      ids = []
      iterate(reader) do |eml_id, cached|
        next if cached.nil?
        ids << eml_id if strip_brackets(cached).downcase == target
      end
      ids
    end

    # Convenience: is there more than one copy of this Message-ID in the tree?
    def self.duplicate?(message_id)
      eml_ids_for(message_id).size > 1
    end

    # Build a Hash{Message-ID => Array<eml_id>} for every duplicated Message-ID
    # in the index. One full pass; useful as a session-cached lookup when many
    # messages will be processed in a batch.
    def self.duplicates
      reader = Mailmate::IndexReader.for("message-id")

      groups = Hash.new { |h, k| h[k] = [] }
      iterate(reader) do |eml_id, cached|
        next if cached.nil? || cached.empty?
        groups[strip_brackets(cached).downcase] << eml_id
      end
      groups.select { |_, ids| ids.size > 1 }
    end

    # Internal — iterate the IndexReader's records. Delegates to the
    # reader's public `each_record` API.
    def self.iterate(reader, &block)
      reader.each_record(&block)
    end

    def self.strip_brackets(s)
      s.to_s.sub(/\A</, "").sub(/>\z/, "").strip
    end
  end
end
