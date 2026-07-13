# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestEmlLookup < Minitest::Test
  include Mailmate::TestHelpers

  # ---- URL → path mapping (pure logic, no MailMate required) ----

  def test_url_to_path_simple_inbox
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/mm" }) do
      url  = "imap://alice%40example.com@imap.example.com/INBOX"
      path = Mailmate::EmlLookup.url_to_path(url, 180535)
      assert_equal "/tmp/mm/Messages.noindex/IMAP/alice%40example.com@imap.example.com/INBOX.mailbox/Messages/180535.eml", path
    end
  end

  def test_url_to_path_nested_gmail
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/mm" }) do
      url  = "imap://alice%40example.com@imap.example.com/[Gmail]/Archive"
      path = Mailmate::EmlLookup.url_to_path(url, 9999)
      assert_equal "/tmp/mm/Messages.noindex/IMAP/alice%40example.com@imap.example.com/[Gmail].mailbox/Archive.mailbox/Messages/9999.eml", path
    end
  end

  def test_url_to_path_mailbox_with_space
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/mm" }) do
      url  = "imap://alice%40example.org@imap.example.org/Deleted Messages"
      path = Mailmate::EmlLookup.url_to_path(url, 42)
      assert_equal "/tmp/mm/Messages.noindex/IMAP/alice%40example.org@imap.example.org/Deleted Messages.mailbox/Messages/42.eml", path
    end
  end

  def test_url_to_path_returns_nil_for_malformed
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/mm" }) do
      assert_nil Mailmate::EmlLookup.url_to_path("imap://no-path-here", 1)
      assert_nil Mailmate::EmlLookup.url_to_path("imap://account@host/", 1)
    end
  end

  # ---- glob fallback ----

  def test_via_glob_finds_eml_in_tree
    Dir.mktmpdir do |dir|
      imap_root = File.join(dir, "Messages.noindex", "IMAP")
      target = File.join(imap_root, "account", "INBOX.mailbox", "Messages", "42.eml")
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "stub")

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        assert_equal target, Mailmate::EmlLookup.via_glob(42)
        assert_nil Mailmate::EmlLookup.via_glob(99999)
      end
    end
  end

  # ---- via_index gracefully handles missing index ----

  def test_via_index_returns_nil_when_index_missing
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/nonexistent-mailmate" }) do
      Mailmate::IndexReader.reset!
      assert_nil Mailmate::EmlLookup.via_index(180535)
    end
  end

  # ---- resolve_id accepts six input forms ----
  #
  # MailMate's URL handler accepts both an integer (eml-id) and a percent-
  # encoded angle-bracketed Message-ID for both the `mid:` and `message://`
  # schemes. resolve_id mirrors that leniency. Stubs the Message-ID index
  # lookup so we exercise the dispatch logic without needing a real index on
  # disk — and so we can assert *what* was looked up, not just the return value.

  def with_stubbed_message_id_lookup(returns: 184058)
    seen = []
    callable = ->(arg) { seen << arg; returns }
    Mailmate::EmlLookup.stub(:eml_id_for_message_id, callable) do
      yield seen
    end
  end

  def test_resolve_id_bare_eml_id_takes_digit_path
    with_stubbed_message_id_lookup do |seen|
      assert_equal 184058, Mailmate::EmlLookup.resolve_id("184058")
      assert_empty seen, "digit input must not hit the Message-ID index"
    end
  end

  def test_resolve_id_bare_message_id_with_brackets
    with_stubbed_message_id_lookup do |seen|
      assert_equal 184058, Mailmate::EmlLookup.resolve_id("<abc@example.com>")
      assert_equal ["<abc@example.com>"], seen
    end
  end

  def test_resolve_id_message_url_with_encoded_message_id
    with_stubbed_message_id_lookup do |seen|
      assert_equal 184058, Mailmate::EmlLookup.resolve_id("message://%3Cabc%40example.com%3E")
      assert_equal ["<abc@example.com>"], seen
    end
  end

  def test_resolve_id_message_url_with_bare_eml_id
    with_stubbed_message_id_lookup do |seen|
      assert_equal 184058, Mailmate::EmlLookup.resolve_id("message://184058")
      assert_empty seen, "message://<eml-id> must take the digit path, not the Message-ID index"
    end
  end

  def test_resolve_id_mid_url_with_encoded_message_id
    with_stubbed_message_id_lookup do |seen|
      assert_equal 184058, Mailmate::EmlLookup.resolve_id("mid:%3Cabc%40example.com%3E")
      assert_equal ["<abc@example.com>"], seen
    end
  end

  def test_resolve_id_mid_url_with_bare_eml_id
    with_stubbed_message_id_lookup do |seen|
      assert_equal 184058, Mailmate::EmlLookup.resolve_id("mid:184058")
      assert_empty seen, "mid:<eml-id> must take the digit path, not the Message-ID index"
    end
  end

  # ---- path_for prefers index over glob ----

  def test_path_for_falls_back_to_glob_when_index_unavailable
    Dir.mktmpdir do |dir|
      imap_root = File.join(dir, "Messages.noindex", "IMAP")
      target = File.join(imap_root, "account", "INBOX.mailbox", "Messages", "42.eml")
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "stub")

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        # No #source index in this synthetic tree; path_for should fall back
        # to the glob walker and still find the file.
        assert_equal target, Mailmate::EmlLookup.path_for(42)
      end
    end
  end

  # ---- via_index rejects stale indexed paths (post-fast-move recovery) ----

  def test_via_index_returns_nil_when_indexed_path_doesnt_exist
    # Simulates the post-fast-move stale window: MailMate's #source still
    # points at the old location, but the .eml has been renamed elsewhere.
    # via_index must not return that stale path — otherwise path_for would
    # short-circuit instead of falling through to via_glob.
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/mailmate-stale-test" }) do
      Mailmate::IndexReader.reset!
      Mailmate::EmlLookup.stub(:source_url_for, ->(_id) { "imap://acct/SomewhereGone" }) do
        assert_nil Mailmate::EmlLookup.via_index(42)
      end
    end
  end

  def test_path_for_recovers_via_glob_when_indexed_path_stale
    Dir.mktmpdir do |dir|
      imap_root = File.join(dir, "Messages.noindex", "IMAP")
      real      = File.join(imap_root, "acct", "INBOX.mailbox", "Messages", "42.eml")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, "stub")

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        # #source URL points at Archive (file isn't there); glob finds the
        # real file in INBOX. Stand-in for the post-fast-move stale window.
        Mailmate::EmlLookup.stub(:source_url_for, ->(_id) { "imap://acct/Archive" }) do
          assert_equal real, Mailmate::EmlLookup.path_for(42)
        end
      end
    end
  end
end
