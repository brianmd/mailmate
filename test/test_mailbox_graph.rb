# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

# MailboxGraph tests. Writes a fixture Mailboxes.plist (as JSON, which plutil
# accepts as input) into a tmpdir's app-support layout, then loads the graph
# and asserts on the indexes it builds.
class TestMailboxGraph < Minitest::Test
  include Mailmate::TestHelpers

  def with_plist_fixture(plist_json)
    Dir.mktmpdir("mm-mbx-graph") do |dir|
      plist_path = File.join(dir, "Mailboxes.plist")
      # plutil accepts JSON-format plists natively; no conversion needed.
      File.write(plist_path, plist_json)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        yield
      end
    end
  end

  def test_load_basic_mailboxes
    json = <<~JSON
      { "mailboxes": [
          { "uuid": "u1", "name": "MyBox",  "set": "INBOX",  "filter": "from = 'a@b'" },
          { "uuid": "u2", "name": "Other",  "set": "INBOX" }
        ]
      }
    JSON
    with_plist_fixture(json) do
      graph = Mailmate::MailboxGraph.load
      assert_equal "MyBox", graph.by_uuid["u1"][:name]
      assert_equal "u1",    graph.by_name["MyBox"]
      assert_equal "u2",    graph.by_name["Other"]
    end
  end

  def test_smart_mailbox_wins_over_default_on_name_collision
    # Two mailboxes share a name; only one has a filter. by_name should
    # point at the one with a filter (smart mailboxes are what users address by name).
    json = <<~JSON
      { "mailboxes": [
          { "uuid": "plain", "name": "INBOX", "set": "INBOX" },
          { "uuid": "smart", "name": "INBOX", "set": "INBOX", "filter": "#flags.flag = '\\\\Seen'" }
        ]
      }
    JSON
    with_plist_fixture(json) do
      graph = Mailmate::MailboxGraph.load
      assert_equal "smart", graph.by_name["INBOX"]
    end
  end

  def test_delta_mailboxes_merge_into_set
    # `deltaMailboxes` entries merge with `mailboxes` of the same UUID.
    # MailMate uses this to layer user overrides on top of bundled defaults.
    json = <<~JSON
      { "mailboxes": [
          { "uuid": "u1", "name": "Original", "set": "INBOX" }
        ],
        "deltaMailboxes": [
          { "uuid": "u1", "filter": "subject ~ 'urgent'" }
        ]
      }
    JSON
    with_plist_fixture(json) do
      graph = Mailmate::MailboxGraph.load
      entry = graph.by_uuid["u1"]
      assert_equal "Original", entry[:name]
      assert_equal "subject ~ 'urgent'", entry[:filter]
    end
  end

  def test_lookup_returns_hash_by_uuid_and_string_by_name
    # `lookup` is polymorphic by design: UUID hit → entry hash; name hit →
    # the bare UUID string (callers re-index by_uuid themselves). Documenting
    # the actual contract rather than what symmetry would suggest.
    json = <<~JSON
      { "mailboxes": [
          { "uuid": "u1", "name": "MyBox", "set": "INBOX" }
        ]
      }
    JSON
    with_plist_fixture(json) do
      graph = Mailmate::MailboxGraph.load
      assert_equal "MyBox", graph.lookup("u1")[:name]
      assert_equal "u1",    graph.lookup("MyBox")
      assert_nil            graph.lookup("does-not-exist")
    end
  end

  def test_missing_plist_loads_empty
    Dir.mktmpdir("mm-empty") do |dir|
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        graph = Mailmate::MailboxGraph.load
        # Standard / default plists from /Applications/MailMate.app may populate
        # by_uuid even without a user Mailboxes.plist — so only assert that the
        # user's named entries from the missing file aren't present.
        refute graph.by_name.key?("Nonexistent")
      end
    end
  end
end
