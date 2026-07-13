# frozen_string_literal: true

# PartLookup — given a `.eml` envelope id, return the body-part-ids of its
# child parts.
#
# MailMate stores each message as a tree of parts: the envelope (which becomes
# the on-disk `.eml` filename) is the root, with text/plain, text/html, and
# attachments as children with their own part-ids. Body content indexes
# (`#unquoted#lc`, `#quoted#lc`, etc.) are keyed by body-part-id, not
# envelope-id — so to read a message's body content from those indexes we
# first have to walk from envelope-id to its children.
#
# Data source: `#root-body-part.{cache,offsets}`, which stores the root
# (envelope) id as a decimal-string value for each non-envelope part-id. We
# invert that mapping once per process: envelope_id → [part_ids].
#
# Memory: ~5 MB for 100k part records. Negligible. Build cost: one IndexReader
# pass, ≈10–30 ms.

module Mailmate
  # @api public
  module PartLookup
    class << self
      # Returns the body-part-ids that descend from `envelope_id`. Returns []
      # for envelopes with no recorded children (single-part messages where
      # envelope-id == body-part-id, and messages MailMate hasn't yet
      # indexed). Order matches `#root-body-part`'s id-iteration order, not
      # MIME-tree order.
      def body_parts_of(envelope_id)
        inversion[envelope_id.to_i] || []
      end

      # Drop the cached inversion. Tests use this with `with_config` swaps;
      # production callers use it when MailMate's index has been rewritten on
      # disk. Cheap — next call rebuilds lazily.
      def reset!
        @inversions = nil
      end

      private

      # The cached inversion is keyed by db_headers AND pinned to the exact
      # IndexReader object it was built from — when IndexReader.for returns a
      # rebuilt reader (file changed on disk; see IndexReader#stale?), the
      # identity check fails and the inversion rebuilds with it. Keeps the
      # persistent MCP server's part map in sync without explicit resets.
      def inversion
        reader = Mailmate::IndexReader.for("#root-body-part")
        @inversions ||= {}
        entry = @inversions[Mailmate.config.db_headers]
        return entry[:inv] if entry && entry[:reader].equal?(reader)
        inv = build_inversion(reader)
        @inversions[Mailmate.config.db_headers] = { reader: reader, inv: inv }
        inv
      end

      def build_inversion(reader)
        inv = Hash.new { |h, k| h[k] = [] }
        reader.each_eml_id do |part_id|
          root_str = reader.value_for(part_id)
          # Skip deleted parts: MailMate appends an empty trailing record to
          # `#root-body-part` when a part is removed. value_for returns that
          # latest record, so empty == "this part is gone."
          next if root_str.nil? || root_str.empty?
          inv[root_str.to_i] << part_id
        end
        inv
      end
    end
  end
end
