# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "mail"

# VarResolver tests. Builds a tiny on-disk IMAP tree under a tmpdir plus an
# in-memory MailboxGraph (no plist parsing required — we poke @by_uuid /
# @by_name directly), then exercises: forward resolution, memoization,
# cycle detection, and unknown-var errors.
class TestVarResolver < Minitest::Test
  include Mailmate::TestHelpers

  def setup
    @tmpdir = Dir.mktmpdir("mm-var-resolver-test")
    @inbox  = File.join(@tmpdir, "Messages.noindex", "IMAP", "acct1.imap", "INBOX.mailbox", "Messages")
    FileUtils.mkdir_p(@inbox)
    write_eml(1, from: "alice@example.com", to: "me@example.com", subject: "Hi from Alice")
    write_eml(2, from: "bob@example.com",   to: "me@example.com", subject: "Hi from Bob")
    write_eml(3, from: "carol@example.com", to: "other@example.com", subject: "Off-topic")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def write_eml(id, from:, to:, subject:)
    body = <<~EML
      From: #{from}
      To: #{to}
      Subject: #{subject}
      Date: Mon, 1 Jan 2026 12:00:00 +0000
      Message-ID: <#{id}@example.com>

      Body text for #{id}.
    EML
    File.write(File.join(@inbox, "#{id}.eml"), body)
  end

  # Build a graph with two smart mailboxes:
  #   MyInbox     — set: INBOX (no filter)
  #   FilteredInbox — set: INBOX, filter: to = 'me@example.com'
  def graph_with_smart_boxes
    graph = Mailmate::MailboxGraph.new
    graph.by_uuid["uuid-myinbox"] = {
      uuid: "uuid-myinbox", name: "MyInbox", set: "INBOX", filter: nil,
    }
    graph.by_uuid["uuid-filtered"] = {
      uuid: "uuid-filtered", name: "FilteredInbox", set: "INBOX",
      filter: "to.address = 'me@example.com'",
    }
    graph.by_name["MyInbox"]       = "uuid-myinbox"
    graph.by_name["FilteredInbox"] = "uuid-filtered"
    graph
  end

  def with_imap_tmpdir
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => @tmpdir }) do
      yield
    end
  end

  # ---- forward resolution ----

  def test_resolve_collects_attribute_across_all_messages
    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph_with_smart_boxes)
      values = resolver.resolve("MyInbox", ["from", "address"])
      assert_equal %w[alice@example.com bob@example.com carol@example.com].sort, values.sort
    end
  end

  def test_resolve_with_filter_narrows_to_matching_messages
    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph_with_smart_boxes)
      values = resolver.resolve("FilteredInbox", ["from", "address"])
      assert_equal %w[alice@example.com bob@example.com].sort, values.sort
    end
  end

  def test_resolve_returns_empty_for_path_with_no_matches
    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph_with_smart_boxes)
      assert_empty resolver.resolve("MyInbox", ["x-missing-header"])
    end
  end

  def test_resolve_works_with_special_uuid
    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph_with_smart_boxes)
      values = resolver.resolve("INBOX", ["from", "address"])
      assert_equal 3, values.size
    end
  end

  # ---- memoization ----

  def test_resolve_caches_results
    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph_with_smart_boxes)
      a = resolver.resolve("MyInbox", ["from", "address"])
      # Delete the .eml files. If memoization is broken, the second call would
      # walk the (now-empty) dir and return []. Cached call should still return
      # the original results.
      FileUtils.rm_f(Dir.glob("#{@inbox}/*.eml"))
      b = resolver.resolve("MyInbox", ["from", "address"])
      assert_equal a, b
    end
  end

  def test_resolve_caches_per_attr_path
    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph_with_smart_boxes)
      froms    = resolver.resolve("MyInbox", ["from", "address"])
      subjects = resolver.resolve("MyInbox", ["subject"])
      refute_equal froms, subjects
      assert_includes subjects, "Hi from Alice"
    end
  end

  # ---- error paths ----

  def test_unknown_var_raises
    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph_with_smart_boxes)
      assert_raises(Mailmate::VarResolver::UnsupportedVar) do
        resolver.resolve("DoesNotExist", ["from"])
      end
    end
  end

  def test_cycle_detection
    # Build two smart mailboxes whose filters reference each other.
    # The lexer only accepts [A-Z_]+ for $VAR names, so use upper-case.
    # Resolving CYCLE_A walks INBOX, evaluates the filter against each .eml,
    # which calls var_resolver.resolve("CYCLE_B", ...) — which walks INBOX
    # again with CYCLE_B's filter, which references CYCLE_A and trips the
    # @visiting guard.
    graph = Mailmate::MailboxGraph.new
    graph.by_uuid["uuid-a"] = {
      uuid: "uuid-a", name: "CYCLE_A", set: "INBOX",
      filter: "subject = $CYCLE_B.subject",
    }
    graph.by_uuid["uuid-b"] = {
      uuid: "uuid-b", name: "CYCLE_B", set: "INBOX",
      filter: "subject = $CYCLE_A.subject",
    }
    graph.by_name["CYCLE_A"] = "uuid-a"
    graph.by_name["CYCLE_B"] = "uuid-b"

    with_imap_tmpdir do
      resolver = Mailmate::VarResolver.new(graph)
      assert_raises(Mailmate::VarResolver::CycleError) do
        resolver.resolve("CYCLE_A", ["subject"])
      end
    end
  end
end
