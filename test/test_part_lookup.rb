# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# PartLookup inverts MailMate's #root-body-part index (which stores
# part_id → root_envelope_id) into envelope_id → [part_ids]. Tests build a
# synthetic #root-body-part fixture to exercise the inversion without needing
# a live MailMate install.
class TestPartLookup < Minitest::Test
  include Mailmate::TestHelpers

  def teardown
    Mailmate::PartLookup.reset!
    Mailmate::IndexReader.reset!
  end

  def test_inverts_simple_two_child_envelope
    # Envelope 100 has body parts 101 (text/plain) and 102 (text/html).
    # Envelope 200 has one body part 201.
    with_root_body_part(records: [
      [101, "100"],
      [102, "100"],
      [201, "200"],
    ]) do
      assert_equal [101, 102], Mailmate::PartLookup.body_parts_of(100).sort
      assert_equal [201], Mailmate::PartLookup.body_parts_of(200)
    end
  end

  def test_returns_empty_for_unknown_envelope
    with_root_body_part(records: [[101, "100"]]) do
      assert_equal [], Mailmate::PartLookup.body_parts_of(99999)
    end
  end

  def test_returns_empty_for_envelope_with_no_recorded_children
    # Envelope 100 is the root of part 101; envelope 200 has no children at
    # all (it's a single-part message where envelope-id IS body-part-id —
    # callers handle that via fallback, not via PartLookup).
    with_root_body_part(records: [[101, "100"]]) do
      assert_equal [], Mailmate::PartLookup.body_parts_of(200)
    end
  end

  def test_skips_deleted_parts
    # MailMate appends an empty trailing record when a part is removed.
    # IndexReader#value_for returns the latest record (empty string) — the
    # inversion must skip these so deleted parts don't pollute the result.
    with_root_body_part(records: [
      [101, "100"],
      [102, "100"], [102, ""],   # part 102 was deleted
      [103, "100"],
    ]) do
      assert_equal [101, 103], Mailmate::PartLookup.body_parts_of(100).sort
    end
  end

  def test_inversion_cached_while_reader_unchanged
    # The inversion is pinned to the IndexReader object it was built from.
    # While the reader stays cached, repeated calls serve the same inversion
    # object — no rebuild.
    Dir.mktmpdir do |dir|
      write_root_body_part(dir, records: [[101, "100"]])
      with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::PartLookup.reset!
        Mailmate::IndexReader.reset!
        assert_equal [101], Mailmate::PartLookup.body_parts_of(100)
        first = Mailmate::PartLookup.send(:inversion)
        assert_same first, Mailmate::PartLookup.send(:inversion),
                    "unchanged reader should serve the cached inversion"
      end
    end
  end

  def test_inversion_follows_index_reader_rebuilds
    # When the reader rebuilds (explicit reset! here; mtime-based staleness
    # detection in long-lived processes), the inversion rebuilds with it —
    # no separate PartLookup.reset! required. This is the MCP-server
    # freshness contract: a rewritten #root-body-part must not serve a
    # part map from the old snapshot.
    Dir.mktmpdir do |dir|
      write_root_body_part(dir, records: [[101, "100"]])
      with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::PartLookup.reset!
        Mailmate::IndexReader.reset!
        assert_equal [101], Mailmate::PartLookup.body_parts_of(100)

        write_root_body_part(dir, records: [[101, "100"], [102, "100"]])
        Mailmate::IndexReader.reset!

        assert_equal [101, 102], Mailmate::PartLookup.body_parts_of(100).sort,
                     "rebuilt reader should invalidate the cached inversion"
      end
    end
  end

  def test_reset_drops_cache
    Dir.mktmpdir do |dir|
      write_root_body_part(dir, records: [[101, "100"]])
      with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::PartLookup.reset!
        Mailmate::IndexReader.reset!
        assert_equal [101], Mailmate::PartLookup.body_parts_of(100)

        write_root_body_part(dir, records: [[101, "100"], [102, "100"]])
        Mailmate::IndexReader.reset!
        Mailmate::PartLookup.reset!

        assert_equal [101, 102], Mailmate::PartLookup.body_parts_of(100).sort
      end
    end
  end

  def test_separate_db_dirs_get_separate_inversions
    Dir.mktmpdir do |dir_a|
      Dir.mktmpdir do |dir_b|
        write_root_body_part(dir_a, records: [[101, "100"]])
        write_root_body_part(dir_b, records: [[201, "200"]])

        Mailmate::PartLookup.reset!
        Mailmate::IndexReader.reset!

        with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir_a }) do
          assert_equal [101], Mailmate::PartLookup.body_parts_of(100)
        end

        # Different db_headers — must NOT serve the dir_a inversion.
        with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir_b }) do
          assert_equal [201], Mailmate::PartLookup.body_parts_of(200)
          assert_equal [], Mailmate::PartLookup.body_parts_of(100)
        end
      end
    end
  end

  private

  # Build a synthetic #root-body-part fixture and yield with config pointing
  # at it. `records` is an array of [part_id, root_str] pairs; the cache is
  # built as newline-joined unique root strings and offsets reference back.
  def with_root_body_part(records:)
    Dir.mktmpdir do |dir|
      write_root_body_part(dir, records: records)
      with_config(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::PartLookup.reset!
        Mailmate::IndexReader.reset!
        yield
      end
    end
  end

  def write_root_body_part(dir, records:)
    headers = File.join(dir, "Database.noindex", "Headers")
    FileUtils.mkdir_p(headers)

    # Build a cache that contains every distinct root string, then build
    # offsets records pointing into it. Multiple identical root strings
    # share the same cache region (mirrors MailMate's actual behavior, but
    # we don't have to be that careful — distinct copies work too).
    cache = String.new
    spans = {}
    records.each do |(_pid, root_str)|
      next if spans.key?(root_str)
      start = cache.bytesize
      cache << root_str
      spans[root_str] = [start, cache.bytesize]
    end

    File.binwrite(File.join(headers, "#root-body-part.cache"), cache)
    offsets = records.map { |(pid, root_str)|
      s, e = spans[root_str]
      [pid, s, e].pack("V3")
    }.join
    File.binwrite(File.join(headers, "#root-body-part.offsets"), offsets)
  end
end
