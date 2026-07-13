# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

# SourceResolver tests. Builds a synthetic IMAP tree under a tmpdir with the
# standard MailMate mailbox layout (INBOX.mailbox, Sent Messages.mailbox,
# Trash.mailbox, etc.), points config at it, and exercises the special-UUID
# resolution paths.
class TestSourceResolver < Minitest::Test
  include Mailmate::TestHelpers

  def with_imap_tree
    Dir.mktmpdir("mm-source-resolver") do |dir|
      imap = File.join(dir, "Messages.noindex", "IMAP")
      # Account 1: iCloud-style flat layout
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "INBOX.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Sent Messages.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Archive.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Deleted Messages.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Junk.mailbox", "Messages"))
      # Account 2: Gmail-style nested layout
      FileUtils.mkdir_p(File.join(imap, "acct2.imap", "INBOX.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct2.imap", "[Gmail].mailbox", "Sent Mail.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct2.imap", "[Gmail].mailbox", "Trash.mailbox", "Messages"))

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        yield
      end
    end
  end

  def empty_graph
    Mailmate::MailboxGraph.new
  end

  # ---- per-account specials ----

  def test_inbox_resolves_across_accounts
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("INBOX")[:dirs]
      assert_equal 2, dirs.size
      assert dirs.any? { |d| d.include?("acct1.imap/INBOX.mailbox") }
      assert dirs.any? { |d| d.include?("acct2.imap/INBOX.mailbox") }
    end
  end

  def test_sent_handles_both_flat_and_gmail_nested
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("SENT")[:dirs]
      assert dirs.any? { |d| d.include?("Sent Messages.mailbox") },        "flat sent missing"
      assert dirs.any? { |d| d.include?("[Gmail].mailbox/Sent Mail.mailbox") }, "gmail sent missing"
    end
  end

  def test_trash_excludes_inbox
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("TRASH")[:dirs]
      refute dirs.any? { |d| d.include?("/INBOX.mailbox/") }
      assert dirs.any? { |d| d.include?("Deleted Messages.mailbox") || d.include?("Trash.mailbox") }
    end
  end

  # ---- ALL_MESSAGES ----

  def test_all_messages_excludes_trash_and_junk
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("ALL_MESSAGES")[:dirs]
      assert dirs.any? { |d| d.include?("INBOX.mailbox") }
      refute dirs.any? { |d| d =~ %r{/Trash\.mailbox/} },          "trash leaked into ALL"
      refute dirs.any? { |d| d =~ %r{/Junk\.mailbox/} },           "junk leaked into ALL"
      refute dirs.any? { |d| d =~ %r{/Deleted Messages\.mailbox/} }, "deleted leaked into ALL"
    end
  end

  # ---- smart-mailbox set chain ----

  def test_smart_mailbox_set_chain_accumulates_filters
    with_imap_tree do
      graph = empty_graph
      # Outer smart mailbox "MyFiltered" points to inner "Stage1" via set;
      # both have filters that must be ANDed when resolving the outer.
      graph.by_uuid["outer"] = { uuid: "outer", name: "MyFiltered", set: "inner", filter: "subject ~ 'a'" }
      graph.by_uuid["inner"] = { uuid: "inner", name: "Stage1",     set: "INBOX", filter: "subject ~ 'b'" }
      graph.by_name["MyFiltered"] = "outer"
      graph.by_name["Stage1"]     = "inner"

      res = Mailmate::SourceResolver.new(graph).resolve("outer")
      assert_includes res[:filters], "subject ~ 'a'"
      assert_includes res[:filters], "subject ~ 'b'"
      refute_empty res[:dirs]
    end
  end

  def test_unresolvable_mailbox_raises
    with_imap_tree do
      graph = empty_graph
      graph.by_uuid["floating"] = { uuid: "floating", name: "Floating" }
      assert_raises(ArgumentError) do
        Mailmate::SourceResolver.new(graph).resolve("floating")
      end
    end
  end
end
