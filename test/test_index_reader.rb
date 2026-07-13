# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# IndexReader decodes MailMate's binary index format. Tests construct synthetic
# .cache + .offsets pairs to exercise the 12-byte-record decode without needing
# a live MailMate install.
class TestIndexReader < Minitest::Test
  include Mailmate::TestHelpers

  def test_decodes_flag_entries
    with_synthetic_index(name: "#flags") do
      reader = Mailmate::IndexReader.for("#flags")
      assert_equal ["\\Seen"], reader.flags_for(4)
      assert_equal ["\\Seen", "$Forwarded"], reader.flags_for(7)
      assert_equal ["\\Flagged", "\\Seen"], reader.flags_for(11)
    end
  end

  def test_unknown_eml_id_returns_empty
    with_synthetic_index(name: "#flags") do
      reader = Mailmate::IndexReader.for("#flags")
      assert_equal [], reader.flags_for(99999)
    end
  end

  def test_empty_range_is_no_flags
    # A record where start == end means "this msg is in the index but has no value."
    with_synthetic_index(name: "#flags", records: [[12, 0, 0]], cache: "\\Seen") do
      reader = Mailmate::IndexReader.for("#flags")
      assert_equal [], reader.flags_for(12)
    end
  end

  def test_size_reports_record_count
    with_synthetic_index(name: "#flags") do
      reader = Mailmate::IndexReader.for("#flags")
      assert_equal 3, reader.size
    end
  end

  def test_value_for_returns_raw_string
    cache = "first\nsecond\nthird"
    # record: eml_id=1, range [6,12) → "second"
    records = [[1, 6, 12]]
    with_synthetic_index(name: "#test", cache: cache, records: records) do
      reader = Mailmate::IndexReader.for("#test")
      assert_equal "second", reader.value_for(1)
    end
  end

  def test_missing_index_raises
    with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/nonexistent-mm" }) do
      Mailmate::IndexReader.reset!
      assert_raises(ArgumentError) do
        Mailmate::IndexReader.for("#flags")
      end
    end
  end

  def test_targeted_reset_keeps_other_indexes_warm
    Dir.mktmpdir do |dir|
      headers_dir = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers_dir)

      # Two synthetic indexes.
      File.binwrite(File.join(headers_dir, "#a.cache"), "value-a")
      File.binwrite(File.join(headers_dir, "#a.offsets"), [1, 0, 7].pack("V3"))
      File.binwrite(File.join(headers_dir, "#b.cache"), "value-b")
      File.binwrite(File.join(headers_dir, "#b.offsets"), [1, 0, 7].pack("V3"))

      with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!

        reader_a_first = Mailmate::IndexReader.for("#a")
        reader_b_first = Mailmate::IndexReader.for("#b")

        # Reset only #a; #b should remain the same in-memory object.
        Mailmate::IndexReader.reset!("#a")

        reader_a_second = Mailmate::IndexReader.for("#a")
        reader_b_second = Mailmate::IndexReader.for("#b")

        refute_same reader_a_first, reader_a_second, "Reset target should be rebuilt"
        assert_same reader_b_first, reader_b_second, "Untouched index should keep its cached reader"
      end
    end
  end

  def test_targeted_reset_for_unknown_name_is_safe
    # Should not raise even if the named index was never cached.
    Mailmate::IndexReader.reset!
    Mailmate::IndexReader.reset!("never-cached")
  end

  def test_each_eml_id_iterates_all_ids
    with_synthetic_index(name: "#flags") do
      ids = Mailmate::IndexReader.for("#flags").each_eml_id.to_a
      assert_equal [4, 7, 11].sort, ids.sort
    end
  end

  def test_each_record_yields_id_and_value_pairs
    with_synthetic_index(name: "#flags") do
      pairs = Mailmate::IndexReader.for("#flags").each_record.to_a
      assert_equal 3, pairs.size
      assert_includes pairs, [4, "\\Seen"]
    end
  end

  # ---- multi-record indexes (body indexes like #unquoted#lc) ----

  # Body indexes store one record per text segment per body-part-id, so a
  # single id can have many records. Mirror that shape with a synthetic
  # fixture: part-id 100 has three segments, part-id 200 has one.
  def test_values_for_returns_every_record_in_offsets_order
    cache = "first segment\nsecond segment\nthird segment\nlonely segment"
    records = [
      [100, 0, 13],    # "first segment"
      [100, 14, 28],   # "second segment"
      [100, 29, 42],   # "third segment"
      [200, 43, 57],   # "lonely segment"
    ]
    with_synthetic_index(name: "#unquoted#lc", cache: cache, records: records) do
      reader = Mailmate::IndexReader.for("#unquoted#lc")
      assert_equal ["first segment", "second segment", "third segment"], reader.values_for(100)
      assert_equal ["lonely segment"], reader.values_for(200)
      assert_equal [], reader.values_for(999)
    end
  end

  # Header indexes like #flags, #source, subject accumulate records as state
  # changes; the latest record (last on disk) is the current value. This is
  # the back-compat behavior the original hash-overwrite implementation
  # accidentally guaranteed.
  def test_value_for_returns_last_record_on_multi_record_id
    cache = "alpha\nbeta\ngamma"
    records = [
      [42, 0, 5],    # "alpha" — stale
      [42, 6, 10],   # "beta"  — stale
      [42, 11, 16],  # "gamma" — current
    ]
    with_synthetic_index(name: "#flags", cache: cache, records: records) do
      reader = Mailmate::IndexReader.for("#flags")
      assert_equal "gamma", reader.value_for(42)
    end
  end

  def test_each_record_flattens_across_multi_record_ids
    cache = "a\nb\nc\nd"
    records = [
      [1, 0, 1],   # "a"
      [1, 2, 3],   # "b"
      [2, 4, 5],   # "c"
      [2, 6, 7],   # "d"
    ]
    with_synthetic_index(name: "#multi", cache: cache, records: records) do
      pairs = Mailmate::IndexReader.for("#multi").each_record.to_a
      assert_equal [[1, "a"], [1, "b"], [2, "c"], [2, "d"]], pairs
    end
  end

  def test_size_counts_distinct_ids_record_count_counts_records
    cache = "a\nb\nc"
    records = [
      [1, 0, 1],
      [1, 2, 3],
      [2, 4, 5],
    ]
    with_synthetic_index(name: "#multi", cache: cache, records: records) do
      reader = Mailmate::IndexReader.for("#multi")
      assert_equal 2, reader.size
      assert_equal 3, reader.record_count
    end
  end

  # ---- ids_matching (inverted substring search) ----

  def test_ids_matching_finds_every_id_with_a_containing_record
    cache = "hello world\ninvoice attached\nanother invoice here"
    records = [
      [1, 0, 11],   # "hello world"
      [2, 12, 28],  # "invoice attached"
      [3, 29, 49],  # "another invoice here"
    ]
    with_synthetic_index(name: "#unquoted#lc", cache: cache, records: records) do
      reader = Mailmate::IndexReader.for("#unquoted#lc")
      assert_equal [2, 3], reader.ids_matching("invoice").keys.sort
      assert_equal [1], reader.ids_matching("hello").keys
      assert_equal [], reader.ids_matching("absent").keys
    end
  end

  def test_ids_matching_rejects_hit_spanning_two_records
    # "cd" exists in the raw cache bytes but straddles the records' boundary
    # — per-segment semantics say that's not a match in either record.
    cache = "abcdef"
    records = [[1, 0, 3], [2, 3, 6]]
    with_synthetic_index(name: "#unquoted#lc", cache: cache, records: records) do
      reader = Mailmate::IndexReader.for("#unquoted#lc")
      assert_equal [], reader.ids_matching("cd").keys
      assert_equal [1], reader.ids_matching("bc").keys
      assert_equal [2], reader.ids_matching("de").keys
    end
  end

  def test_ids_matching_reports_all_ids_sharing_a_range
    # Two records pointing at the same cache bytes (deduped values) must
    # both surface.
    cache = "spark"
    records = [[1, 0, 5], [2, 0, 5]]
    with_synthetic_index(name: "#unquoted#lc", cache: cache, records: records) do
      assert_equal [1, 2], Mailmate::IndexReader.for("#unquoted#lc").ids_matching("spark").keys.sort
    end
  end

  def test_ids_matching_dedupes_multiple_hits_in_one_record
    cache = "spark and spark again"
    records = [[7, 0, 21]]
    with_synthetic_index(name: "#unquoted#lc", cache: cache, records: records) do
      assert_equal [7], Mailmate::IndexReader.for("#unquoted#lc").ids_matching("spark").keys
    end
  end

  def test_ids_matching_empty_needle_matches_nothing
    with_synthetic_index(name: "#unquoted#lc", cache: "abc", records: [[1, 0, 3]]) do
      assert_equal [], Mailmate::IndexReader.for("#unquoted#lc").ids_matching("").keys
    end
  end

  # ---- malformed inputs ----

  def test_offsets_size_not_multiple_of_12_drops_trailing_bytes
    # 1 full record (12 bytes) + 5 trailing garbage bytes. Reader should
    # process the 1 record and silently ignore the trailing partial record.
    Dir.mktmpdir do |dir|
      headers = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers)
      File.binwrite(File.join(headers, "#malformed.cache"), "value-x")
      offsets = [1, 0, 7].pack("V3") + "junky"
      File.binwrite(File.join(headers, "#malformed.offsets"), offsets)

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        reader = Mailmate::IndexReader.for("#malformed")
        assert_equal 1, reader.size
        assert_equal "value-x", reader.value_for(1)
      end
    end
  end

  def test_offsets_past_cache_end_returns_partial_or_nil
    # Cache is 5 bytes, but the record says end=999. Ruby's slice clamps
    # to the available bytes — we get whatever's there, no exception.
    Dir.mktmpdir do |dir|
      headers = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers)
      File.binwrite(File.join(headers, "#oob.cache"), "short")
      File.binwrite(File.join(headers, "#oob.offsets"), [1, 0, 999].pack("V3"))

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        reader = Mailmate::IndexReader.for("#oob")
        v = reader.value_for(1)
        # Either nil or the truncated "short" — both acceptable; Ruby's
        # behavior here is "return what you can without raising."
        assert v.nil? || v == "short", "expected nil or 'short', got #{v.inspect}"
      end
    end
  end

  def test_empty_cache_with_zero_range
    Dir.mktmpdir do |dir|
      headers = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers)
      File.binwrite(File.join(headers, "#empty.cache"), "")
      File.binwrite(File.join(headers, "#empty.offsets"), [42, 0, 0].pack("V3"))

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        reader = Mailmate::IndexReader.for("#empty")
        assert_equal 1, reader.size
        assert_equal "", reader.value_for(42)
        assert_equal [], reader.flags_for(42)
      end
    end
  end

  def test_cache_is_partitioned_by_db_headers
    # Two tmpdirs holding distinct #flags indexes. Swapping configs between
    # them should return distinct readers, not a stale cached one.
    Dir.mktmpdir do |dir_a|
      Dir.mktmpdir do |dir_b|
        write_flags(dir_a, eml_id: 1, cache: "\\Seen")
        write_flags(dir_b, eml_id: 1, cache: "\\Flagged")

        with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir_a }) do
          assert_equal ["\\Seen"], Mailmate::IndexReader.for("#flags").flags_for(1)
        end

        # Different config — must NOT serve the dir_a reader from cache.
        with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir_b }) do
          assert_equal ["\\Flagged"], Mailmate::IndexReader.for("#flags").flags_for(1)
        end
      end
    end
  end

  private

  def write_flags(dir, eml_id:, cache:)
    headers = File.join(dir, "Database.noindex", "Headers")
    FileUtils.mkdir_p(headers)
    File.binwrite(File.join(headers, "#flags.cache"), cache)
    File.binwrite(File.join(headers, "#flags.offsets"), [eml_id, 0, cache.bytesize].pack("V3"))
  end

  private

  # Build a synthetic Database.noindex/Headers/<name>.{cache,offsets} pair in a
  # tmpdir, point Mailmate.config at it, yield, then clean up.
  #
  # Default records correspond to:
  #   eml_id=4  flags="\Seen"               (cache 0..5)
  #   eml_id=7  flags="\Seen $Forwarded"    (cache 6..21)
  #   eml_id=11 flags="\Flagged \Seen"      (cache 22..37)
  def with_synthetic_index(name:, cache: nil, records: nil)
    cache ||= "\\Seen\n\\Seen $Forwarded\n\\Flagged \\Seen"
    # "\Seen" = 5 bytes; "\Seen $Forwarded" = 16 bytes; "\Flagged \Seen" = 14 bytes.
    # Newlines separate them at positions 5 and 22.
    records ||= [
      [4,  0,  5],    # "\Seen"
      [7,  6,  22],   # "\Seen $Forwarded"
      [11, 23, 37],   # "\Flagged \Seen"
    ]
    Dir.mktmpdir do |dir|
      headers_dir = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers_dir)

      File.binwrite(File.join(headers_dir, "#{name}.cache"), cache)
      offsets_bytes = records.map { |r| r.pack("V3") }.join
      File.binwrite(File.join(headers_dir, "#{name}.offsets"), offsets_bytes)

      with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        yield
      end
    end
  end
end
