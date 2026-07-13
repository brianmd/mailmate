# frozen_string_literal: true

# IndexReader — decodes MailMate's binary header indexes at
# `~/Library/Application Support/MailMate/Database.noindex/Headers/`.
#
# Index format (verified against `#flags.offsets` and `#forwarding.offsets`):
#
#   .cache    Newline-separated string table.
#   .offsets  Concatenated 12-byte records, three little-endian uint32 each:
#               [0..4)   message body-part ID
#               [4..8)   start byte offset into .cache
#               [8..12)  end byte offset into .cache (exclusive)
#             value = cache[start...end]   (start == end → empty / "no value")
#   .plist    Old-style plist with offsetsFileSize / stringsFileSize sentinels.
#
# Most indexes have multiple records per id even when they're conceptually
# 1:1 (header indexes accumulate stale records as messages change; e.g.
# `#flags` for a single id can have dozens of records, one per flag change,
# with the latest at the end). Body indexes (`#unquoted#lc`, `#quoted#lc`)
# are intentionally multi-record: one record per text segment of each body
# part. The accessor pair handles both cases:
#
#   value_for(id)   → LAST record for the id (matches the on-disk
#                     "latest-version" semantics for accumulator-style
#                     indexes; for genuinely multi-record indexes like body
#                     content, the last record alone is meaningless — use
#                     values_for there).
#   values_for(id)  → all records for the id, in offsets-file order.
#   each_record     → yields (id, value) once per on-disk record. Multi-record
#                     ids yield multiple times; 1:1 ids yield once.
#
# Specific accessors:
#   `flags.flag(eml_id)`  → Array<String> of IMAP keywords (`\Seen`,
#                            `\Flagged`, `$Forwarded`, `$Muted`, custom tags…)
#                            or [] if the message has no flags / isn't indexed.
#
# IndexReader instances cache both files in memory and build a hash from
# id → [packed_range, …] (start << 32 | end, one Integer per record) for
# O(1) lookup. Construction cost ≈ 5–20 ms for 50–200k records (one bulk
# unpack("V*") pass); memory ≈ a few MB. For a CLI invocation that's fine;
# the evaluator instantiates one lazily when first needed.

module Mailmate
  # @api public
  class IndexReader
    RECORD_SIZE = 12

    # Re-stat the underlying files at most this often per reader (seconds).
    # Short-lived CLI processes never hit the recheck; the persistent MCP
    # server picks up MailMate's continuous index rewrites within this window
    # instead of serving a snapshot from its first request forever.
    FRESHNESS_INTERVAL = 1.0

    class << self
      # Per-process cache of readers keyed by [name, db_headers]. Including
      # db_headers means a Mailmate.config swap (e.g. a test pointing at a
      # different tmpdir) doesn't return stale readers built from the old
      # path. Cached readers are re-validated against the on-disk files'
      # mtime+size (throttled; see FRESHNESS_INTERVAL) so long-lived
      # processes don't serve stale data after MailMate rewrites an index.
      def for(name)
        @cache ||= {}
        key = cache_key(name)
        @cache.delete(key) if @cache[key]&.stale?
        @cache[key] ||= new(name)
      end

      # Invalidate cached readers. With no argument, drops the entire cache
      # (useful for tests or when MailMate's database swaps out). With a name,
      # invalidates only entries for that name across all db_headers — the
      # common case (cache-bust after a write) doesn't need to thread config
      # through.
      def reset!(name = nil)
        if name.nil?
          @cache = nil
        elsif @cache
          @cache.delete_if { |(n, _dir), _reader| n == name }
        end
      end

      private

      def cache_key(name)
        [name, Mailmate.config.db_headers]
      end
    end

    attr_reader :name

    def initialize(name)
      @name = name
      @base = "#{Mailmate.config.db_headers}/#{name}"
      raise ArgumentError, "Index not found: #{name} (looked at #{@base}.{cache,offsets})" \
        unless File.exist?("#{@base}.cache") && File.exist?("#{@base}.offsets")

      @cache_bytes   = File.binread("#{@base}.cache")
      @offsets_bytes = File.binread("#{@base}.offsets")
      @cache_sig     = file_sig("#{@base}.cache")
      @offsets_sig   = file_sig("#{@base}.offsets")
      @checked_at    = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # The id→ranges hash builds lazily (see index): ids_matching-only
      # consumers (the inverted body search) never need it, and skipping it
      # saves ~250 ms of construction on the big body indexes.
      @index = nil
    end

    # True when the on-disk files no longer match what this reader was built
    # from. Throttled to one stat-pair per FRESHNESS_INTERVAL; a vanished
    # file (mid-swap while MailMate rewrites) counts as not-stale so we keep
    # serving the last good snapshot rather than racing the writer.
    def stale?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false if now - @checked_at < FRESHNESS_INTERVAL
      @checked_at = now
      cache_sig   = file_sig("#{@base}.cache")
      offsets_sig = file_sig("#{@base}.offsets")
      return false if cache_sig.nil? || offsets_sig.nil?
      cache_sig != @cache_sig || offsets_sig != @offsets_sig
    end

    # Returns the raw cached value for a given .eml body-part ID, or nil if
    # the id isn't in this index. Returns the LAST record for the id — for
    # accumulator-style header indexes (`#flags`, `#source`, `subject`, etc.)
    # that's the latest state; the older records are stale versions. For
    # body indexes (`#unquoted#lc`, `#quoted#lc`) last-alone is meaningless
    # — use values_for to read every segment.
    def value_for(eml_id)
      packs = index[eml_id.to_i]
      return nil if packs.nil? || packs.empty?
      v = packs[-1]
      @cache_bytes[(v >> 32)...(v & 0xFFFFFFFF)]
    end

    # Returns every recorded value for an id, in offsets-file order. Returns
    # [] if the id isn't in the index. Use this for body indexes
    # (#unquoted#lc, #quoted#lc), which store one record per text segment.
    def values_for(eml_id)
      packs = index[eml_id.to_i]
      return [] if packs.nil?
      packs.map { |v| @cache_bytes[(v >> 32)...(v & 0xFFFFFFFF)] }
    end

    # `#flags.flag` semantics: the cache stores a space-separated list of IMAP
    # keywords. Split into individual flag tokens.
    def flags_for(eml_id)
      v = value_for(eml_id)
      return [] if v.nil? || v.empty?
      v.split(/\s+/).reject(&:empty?)
    end

    # True when the index has at least one record for this id. Cheaper than
    # values_for(id).empty? — no substring slicing.
    def key?(eml_id)
      index.key?(eml_id.to_i)
    end

    # Inverted substring search: returns a Hash whose keys are every id with
    # at least one record containing `needle` (byte-wise; pass pre-downcased
    # bytes when querying an #lc index). One memchr-fast String#index scan
    # of the whole cache instead of one substring test per record — for a
    # 77 MB body cache that's ~75 ms versus seconds of per-message lookups.
    #
    # A raw cache hit can span two adjacent records' ranges; interval
    # stabbing keeps only hits that fall entirely inside a single record
    # (per-segment semantics, matching MailMate's own body search). Records
    # sharing a byte range (deduped values) all report their ids.
    def ids_matching(needle)
      needle = needle.b
      found = {}
      return found if needle.empty? || @cache_bytes.empty?
      ensure_stab_table!
      nlen = needle.bytesize
      pos = 0
      while (pos = @cache_bytes.index(needle, pos))
        stab(pos, pos + nlen) { |id| found[id] = true }
        pos += 1
      end
      found
    end

    # Number of distinct ids in the index. For multi-record indexes this is
    # smaller than the on-disk record count (use record_count for that).
    def size
      index.size
    end

    # Total number of on-disk records (sum across all ids). Diagnostics.
    def record_count
      index.values.sum(&:size)
    end

    # Iterate every recorded eml-id. Yields just the id; callers that also
    # want the value should pair this with `value_for`. Exists so other gem
    # modules don't have to reach into `@index` directly.
    def each_eml_id(&block)
      return enum_for(:each_eml_id) unless block
      index.each_key(&block)
    end

    # Iterate every (eml_id, raw_value) pair, once per on-disk record.
    # Multi-record ids yield multiple times. The value comes back as the bare
    # cache substring; callers that need parsed form (e.g. flag tokens)
    # should massage it themselves.
    def each_record
      return enum_for(:each_record) unless block_given?
      index.each do |eml_id, packs|
        packs.each { |v| yield eml_id, @cache_bytes[(v >> 32)...(v & 0xFFFFFFFF)] }
      end
    end

    private

    # Lazy tables for ids_matching's interval stabbing, built once per
    # reader snapshot (a rebuilt reader starts fresh, so staleness handling
    # comes for free). @stab_flat is the raw [id, start, end, …] triple
    # stream; @stab_order holds record numbers sorted by start;
    # @stab_prefix_max_end[i] is the max end among @stab_order[0..i], which
    # lets stab() stop walking left as soon as no earlier-starting record
    # could still reach the queried range. Integers only — no per-record
    # object allocations.
    def ensure_stab_table!
      return if @stab_order
      flat = @offsets_bytes.unpack("V*")
      recs = (flat.size - (flat.size % 3)) / 3
      # Pack (start, recnum) into one Integer and sort! with native compare —
      # a sort_by block is ~3× slower at this record count. start sorts as
      # the high bits; recnum keeps the low bits unique.
      packed = Array.new(recs) { |k| (flat[k * 3 + 1] << 32) | k }
      packed.sort!
      order = packed
      order.map! { |p| p & 0xFFFFFFFF }
      prefix = Array.new(recs)
      max_end = -1
      order.each_with_index do |k, i|
        e = flat[k * 3 + 2]
        max_end = e if e > max_end
        prefix[i] = max_end
      end
      @stab_flat = flat
      @stab_order = order
      @stab_prefix_max_end = prefix
    end

    # Yields the id of every record whose [start, end) range fully contains
    # [lo, hi). Classic stabbing query over ranges sorted by start: binary
    # search to the last range starting at or before lo, then walk left
    # while the prefix-max end says a covering range is still possible —
    # O(log n + overlap depth), and body-index ranges rarely overlap.
    def stab(lo, hi)
      order = @stab_order
      flat = @stab_flat
      i = order.bsearch_index { |k| flat[k * 3 + 1] > lo }
      i = i.nil? ? order.size - 1 : i - 1
      while i >= 0 && @stab_prefix_max_end[i] >= hi
        k = order[i]
        yield flat[k * 3] if flat[k * 3 + 1] <= lo && flat[k * 3 + 2] >= hi
        i -= 1
      end
    end

    def file_sig(path)
      st = File.stat(path)
      [st.mtime, st.size]
    rescue SystemCallError
      nil
    end

    # Decode the offsets file in one bulk unpack — one C call instead of one
    # String#[] + unpack per record (2× faster on the 730k-record body
    # indexes). Each (start, end) range is packed into a single Integer
    # (start << 32 | end) so a record costs an immediate value, not a
    # two-element Array; accessors decode with shift/mask. Caches are tens
    # of MB, so both halves fit 32 bits with room to spare. unpack("V*")
    # silently drops trailing bytes that don't fill a uint32; the % 3 guard
    # drops a trailing partial record.
    def build_index
      h = {}
      flat = @offsets_bytes.unpack("V*")
      n = flat.size - (flat.size % 3)
      i = 0
      while i < n
        (h[flat[i]] ||= []) << ((flat[i + 1] << 32) | flat[i + 2])
        i += 3
      end
      h
    end

    # Lazy id→ranges hash: built on first keyed access, skipped entirely by
    # ids_matching-only consumers (the inverted body search).
    def index
      @index ||= build_index
    end
  end
end
