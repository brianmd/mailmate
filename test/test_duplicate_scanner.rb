# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestDuplicateScanner < Minitest::Test
  include Mailmate::TestHelpers

  # ---- Construction (a small synthetic message-id index) ----

  # `eml_to_msgid` is a Hash{Integer => String} of (eml_id → message-id).
  # Returns the tmpdir path so the caller can scope `with_config` to it.
  def build_message_id_index(eml_to_msgid)
    Dir.mktmpdir do |dir|
      headers_dir = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers_dir)

      # Build the cache as concatenated message-id strings; offsets index into it.
      cache = +""
      records = []
      eml_to_msgid.each do |eml_id, msgid|
        start = cache.bytesize
        cache << msgid
        records << [eml_id, start, cache.bytesize]
      end

      File.binwrite(File.join(headers_dir, "message-id.cache"), cache)
      File.binwrite(File.join(headers_dir, "message-id.offsets"), records.map { |r| r.pack("V3") }.join)

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        yield
      end
    end
  end

  # ---- eml_ids_for ----

  def test_finds_single_copy
    build_message_id_index(100 => "abc@example.com") do
      ids = Mailmate::DuplicateScanner.eml_ids_for("abc@example.com")
      assert_equal [100], ids
    end
  end

  def test_finds_multiple_copies
    build_message_id_index(
      100 => "shared@example.com",
      200 => "shared@example.com",
      300 => "unique@example.com",
    ) do
      ids = Mailmate::DuplicateScanner.eml_ids_for("shared@example.com")
      assert_equal [100, 200], ids.sort
    end
  end

  def test_tolerates_angle_brackets_on_either_side
    build_message_id_index(100 => "abc@example.com") do
      assert_equal [100], Mailmate::DuplicateScanner.eml_ids_for("<abc@example.com>")
    end
    build_message_id_index(100 => "<abc@example.com>") do
      assert_equal [100], Mailmate::DuplicateScanner.eml_ids_for("abc@example.com")
    end
  end

  def test_case_insensitive_match
    build_message_id_index(100 => "ABC@Example.COM") do
      assert_equal [100], Mailmate::DuplicateScanner.eml_ids_for("abc@example.com")
    end
  end

  def test_empty_or_nil_message_id_returns_empty
    build_message_id_index(100 => "abc@example.com") do
      assert_equal [], Mailmate::DuplicateScanner.eml_ids_for("")
      assert_equal [], Mailmate::DuplicateScanner.eml_ids_for(nil)
    end
  end

  # ---- duplicate? ----

  def test_duplicate_predicate_true
    build_message_id_index(
      100 => "shared@example.com",
      200 => "shared@example.com",
    ) do
      assert Mailmate::DuplicateScanner.duplicate?("shared@example.com")
    end
  end

  def test_duplicate_predicate_false_for_singletons
    build_message_id_index(100 => "unique@example.com") do
      refute Mailmate::DuplicateScanner.duplicate?("unique@example.com")
    end
  end

  # ---- duplicates (bulk scan) ----

  def test_duplicates_groups_by_message_id
    build_message_id_index(
      1 => "a@example.com",
      2 => "b@example.com",
      3 => "b@example.com",
      4 => "c@example.com",
      5 => "c@example.com",
      6 => "c@example.com",
    ) do
      dups = Mailmate::DuplicateScanner.duplicates
      assert_equal 2, dups.size, "Two distinct duplicated Message-IDs"
      assert_equal [2, 3].sort, dups["b@example.com"].sort
      assert_equal [4, 5, 6].sort, dups["c@example.com"].sort
      refute dups.key?("a@example.com"), "Singletons not in duplicates map"
    end
  end

  def test_duplicates_returns_empty_when_no_duplicates
    build_message_id_index(
      1 => "a@example.com",
      2 => "b@example.com",
    ) do
      assert_empty Mailmate::DuplicateScanner.duplicates
    end
  end
end
