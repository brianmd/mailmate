# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/modify"
require "stringio"

# Tests for Mailmate::CLI::Modify helpers — parse_options, parse_actions,
# warn_on_duplicates. The driver (AppleScript) is hard to test without a
# live MailMate; `run` end-to-end stays out of unit tests.
class TestCliModify < Minitest::Test
  include Mailmate::TestHelpers

  M = Mailmate::CLI::Modify

  # ---- parse_options ----

  def test_parse_options_defaults
    argv = []
    opts, _parser = M.parse_options(argv)
    refute opts[:verify]
    refute opts[:dry_run]
    refute opts[:keep_window]
    assert_in_delta 3.5, opts[:settle], 0.0001
  end

  def test_parse_options_flags
    argv = ["--verify", "--dry-run", "--keep-window", "--settle", "1.0"]
    opts, _parser = M.parse_options(argv)
    assert opts[:verify]
    assert opts[:dry_run]
    assert opts[:keep_window]
    assert_in_delta 1.0, opts[:settle], 0.0001
  end

  def test_parse_options_leaves_positionals
    argv = ["--dry-run", "1234", "flag"]
    opts, _parser = M.parse_options(argv)
    assert opts[:dry_run]
    assert_equal ["1234", "flag"], argv
  end

  # ---- parse_actions ----

  def fake_parser
    OptionParser.new # arg for warn output; not asserted in tests
  end

  def test_parse_actions_simple_zero_arg
    actions = M.parse_actions(["read"], fake_parser)
    assert_equal [["read", "markAsRead:", []]], actions
  end

  def test_parse_actions_with_arg
    actions = M.parse_actions(["tag", "urgent"], fake_parser)
    assert_equal [["tag", "setTag:", ["urgent"]]], actions
  end

  def test_parse_actions_multiple_chained
    actions = M.parse_actions(["read", "flag", "tag", "urgent"], fake_parser)
    assert_equal 3, actions.size
    assert_equal "read", actions[0].first
    assert_equal "flag", actions[1].first
    assert_equal "tag",  actions[2].first
    assert_equal ["urgent"], actions[2][2]
  end

  def test_parse_actions_missing_arg_returns_nil
    capture_warn do
      assert_nil M.parse_actions(["tag"], fake_parser)
    end
  end

  def test_parse_actions_unknown_action_returns_nil
    capture_warn do
      assert_nil M.parse_actions(["sneeze"], fake_parser)
    end
  end

  def test_parse_actions_flag_uses_symbol_selector
    actions = M.parse_actions(["flag"], fake_parser)
    assert_equal :ensure_flagged, actions.first[1]
  end

  def test_parse_actions_move_takes_one_arg
    actions = M.parse_actions(["move", "ABC-123"], fake_parser)
    assert_equal [["move", "moveToMailbox:", ["ABC-123"]]], actions
  end

  # ---- run: input resolution ----

  def test_run_missing_id_returns_2
    code = nil
    capture_warn { code = M.run([]) }
    assert_equal 2, code
  end

  def test_run_unresolvable_id_returns_1
    # Mirrors test_cli_message's resolver test: a non-digit input is treated
    # as a candidate Message-ID; resolve_id walks the message-id index and
    # returns nil when no match. mm-modify reports "Not found" (exit 1).
    Dir.mktmpdir do |dir|
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        code = nil
        capture_warn { code = M.run(["abc", "tag", "urgent"]) }
        assert_equal 1, code
      end
    end
  end

  # ---- warn_on_duplicates ----

  def test_warn_on_duplicates_silent_when_only_one
    # DuplicateScanner.eml_ids_for reads the message-id index. Build a
    # minimal one with a single record so the scanner returns [eml_id] —
    # not >1 → no warning.
    Dir.mktmpdir do |dir|
      headers = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers)
      mid = "<x@y>"
      File.binwrite(File.join(headers, "message-id.cache"), mid)
      File.binwrite(File.join(headers, "message-id.offsets"), [1, 0, mid.bytesize].pack("V3"))

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        out = capture_warn { M.warn_on_duplicates(mid, "1") }
        assert_equal "", out
      end
    end
  end

  # ---- fast-path move (direct .eml rename, no AppleScript) ----

  # Build a synthetic IMAP tree under tmpdir with one account, two
  # mailboxes (INBOX and Archive), and one .eml in INBOX. Returns
  # [account_dir, eml_path].
  def build_fake_tree(dir, eml_id: 184058)
    imap = File.join(dir, "Messages.noindex", "IMAP")
    account_dir = File.join(imap, "alice%40example.com@imap.example.com")
    inbox_msgs   = File.join(account_dir, "INBOX.mailbox",   "Messages")
    archive_msgs = File.join(account_dir, "Archive.mailbox", "Messages")
    FileUtils.mkdir_p(inbox_msgs)
    FileUtils.mkdir_p(archive_msgs)
    eml_path = File.join(inbox_msgs, "#{eml_id}.eml")
    File.write(eml_path, "stub")
    [account_dir, eml_path]
  end

  def test_account_dir_for_extracts_first_segment_under_imap_root
    Dir.mktmpdir do |dir|
      account_dir, eml_path = build_fake_tree(dir)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        assert_equal account_dir, M.account_dir_for(eml_path)
      end
    end
  end

  def test_account_dir_for_returns_nil_outside_imap_root
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/mm" }) do
      assert_nil M.account_dir_for("/not/under/imap/root.eml")
    end
  end

  def test_find_target_in_account_matches_bare_name
    Dir.mktmpdir do |dir|
      account_dir, _ = build_fake_tree(dir)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        target = M.find_target_in_account(account_dir, "Archive")
        assert_equal File.join(account_dir, "Archive.mailbox", "Messages"), target
      end
    end
  end

  def test_find_target_in_account_returns_nil_when_unknown
    Dir.mktmpdir do |dir|
      account_dir, _ = build_fake_tree(dir)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        assert_nil M.find_target_in_account(account_dir, "DoesNotExist")
      end
    end
  end

  def test_try_fast_move_renames_eml_in_same_account
    Dir.mktmpdir do |dir|
      _account_dir, eml_path = build_fake_tree(dir, eml_id: 42)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        out = capture_stdout do
          new_path = M.try_fast_move(42, eml_path, "Archive", { dry_run: false })
          assert new_path.end_with?("Archive.mailbox/Messages/42.eml"),
            "expected new path under Archive, got #{new_path.inspect}"
        end
        refute File.exist?(eml_path),    "source .eml should have been renamed away"
        assert File.exist?(File.join(File.dirname(eml_path), "..", "..", "Archive.mailbox", "Messages", "42.eml")),
          "destination .eml should exist after rename"
        assert_includes out, "move (fast): renamed"
      end
    end
  end

  def test_try_fast_move_dry_run_doesnt_touch_disk
    Dir.mktmpdir do |dir|
      _account_dir, eml_path = build_fake_tree(dir, eml_id: 42)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        out = capture_stdout do
          new_path = M.try_fast_move(42, eml_path, "Archive", { dry_run: true })
          refute_nil new_path
        end
        assert File.exist?(eml_path), "source .eml must NOT be moved in dry-run"
        assert_includes out, "dry-run"
      end
    end
  end

  def test_try_fast_move_returns_nil_when_target_unknown
    Dir.mktmpdir do |dir|
      _account_dir, eml_path = build_fake_tree(dir, eml_id: 42)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        # No-op suppress: capture stdout in case future versions print on failure
        capture_stdout do
          assert_nil M.try_fast_move(42, eml_path, "DoesNotExist", { dry_run: false })
        end
        assert File.exist?(eml_path), "source .eml must stay put when fast-move declines"
      end
    end
  end

  def test_try_fast_move_no_op_when_already_in_target
    Dir.mktmpdir do |dir|
      _account_dir, eml_path = build_fake_tree(dir, eml_id: 42)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        out = capture_stdout do
          # Move to where it already is — should report no-op and return path.
          new_path = M.try_fast_move(42, eml_path, "INBOX", { dry_run: false })
          assert_equal eml_path, new_path
        end
        assert_includes out, "no-op"
      end
    end
  end

  # ---- preserve-read-state: opening the mid: URL marks the message read ----
  #
  # Policy: if the user's action chain doesn't explicitly touch read state
  # (read/unread), and the message is currently unread, we re-mark it
  # unread after the open so opening doesn't silently flip it. The check
  # is skipped in dry-run (no real open) and skipped when the user is
  # already controlling read state.

  def with_seen_stub(seen:, &block)
    M.stub(:current_flags, ->(_id) { seen ? ["\\Seen"] : [] }, &block)
  end

  def test_should_preserve_unread_when_unread_and_no_read_action
    with_seen_stub(seen: false) do
      actions = [["tag", "setTag:", ["urgent"]]]
      assert M.should_preserve_unread?(42, actions, { dry_run: false })
    end
  end

  def test_should_preserve_unread_false_when_already_read
    with_seen_stub(seen: true) do
      actions = [["tag", "setTag:", ["urgent"]]]
      refute M.should_preserve_unread?(42, actions, { dry_run: false })
    end
  end

  def test_should_preserve_unread_false_when_chain_marks_read
    with_seen_stub(seen: false) do
      actions = [["tag", "setTag:", ["urgent"]], ["read", "markAsRead:", []]]
      refute M.should_preserve_unread?(42, actions, { dry_run: false })
    end
  end

  def test_should_preserve_unread_false_when_chain_marks_unread
    # User-supplied `unread` already does the right thing; no need to also
    # auto-restore (would be a redundant duplicate selector).
    with_seen_stub(seen: false) do
      actions = [["unread", "markAsUnread:", []]]
      refute M.should_preserve_unread?(42, actions, { dry_run: false })
    end
  end

  def test_should_preserve_unread_false_in_dry_run
    # Dry-run never really opens the message, so there's nothing to undo.
    with_seen_stub(seen: false) do
      actions = [["tag", "setTag:", ["urgent"]]]
      refute M.should_preserve_unread?(42, actions, { dry_run: true })
    end
  end

  # ---- drive() partition: when does fast-path actually run? ----
  #
  # Policy: fast-path applies only when EVERY requested action is a move.
  # Any non-move action in the chain → everything (including the move) goes
  # through the AppleScript driver, so MailMate stays consistent with itself.

  def test_drive_pure_move_uses_fast_path
    fast_calls = 0
    ascript_calls = 0
    M.stub(:try_fast_move, ->(_id, _path, _target, _opts) { fast_calls += 1; "/new/path/42.eml" }) do
      M.stub(:drive_via_applescript, ->(*_args) { ascript_calls += 1 }) do
        Mailmate::EmlLookup.stub(:path_for, ->(_id) { "/original/42.eml" }) do
          M.drive(42, "<m@x>", [["move", "moveToMailbox:", ["Archive"]]], {})
        end
      end
    end
    assert_equal 1, fast_calls,  "pure-move chain must hit the fast path"
    assert_equal 0, ascript_calls, "pure-move chain must NOT activate the AppleScript driver"
  end

  def test_drive_mixed_chain_skips_fast_path
    fast_calls = 0
    seen_actions = nil
    M.stub(:try_fast_move, ->(*_args) { fast_calls += 1; "/never/called" }) do
      M.stub(:drive_via_applescript, ->(_eml, _mid, actions, _opts) { seen_actions = actions }) do
        Mailmate::EmlLookup.stub(:path_for, ->(_id) { "/p/42.eml" }) do
          actions = [["tag",  "setTag:",        ["urgent"]],
                     ["move", "moveToMailbox:", ["Archive"]]]
          M.drive(42, "<m@x>", actions, {})
        end
      end
    end
    assert_equal 0, fast_calls, "mixed chain must NOT use the fast path"
    assert_equal 2, seen_actions.size, "all actions (including the move) must reach AppleScript"
    assert_equal "move", seen_actions.last.first, "user-supplied order is preserved"
  end

  def test_drive_multiple_moves_only_still_uses_fast_path
    fast_calls = 0
    M.stub(:try_fast_move, ->(_id, _path, _target, _opts) { fast_calls += 1; "/p/42.eml" }) do
      M.stub(:drive_via_applescript, ->(*_args) { flunk "AppleScript path must not run for pure-move chain" }) do
        Mailmate::EmlLookup.stub(:path_for, ->(_id) { "/orig/42.eml" }) do
          M.drive(42, "<m@x>", [["move", "moveToMailbox:", ["A"]],
                                ["move", "moveToMailbox:", ["B"]]], {})
        end
      end
    end
    assert_equal 2, fast_calls
  end

  # ---- verifiable_expectations: which chains get effect-checked ----

  def test_verifiable_expectations_for_simple_flag_actions
    exps = M.verifiable_expectations([["read", "markAsRead:", []]])
    assert_equal [[:seen, true]], exps
  end

  def test_verifiable_expectations_collects_tags
    exps = M.verifiable_expectations([["tag", "setTag:", ["urgent"]],
                                      ["flag", :ensure_flagged, []]])
    assert_includes exps, [:tag_present, "urgent"]
    assert_includes exps, [:flagged, true]
  end

  def test_verifiable_expectations_last_write_wins_same_flag
    # tag then untag the SAME name → net expectation is "absent".
    exps = M.verifiable_expectations([["tag", "setTag:", ["x"]],
                                      ["untag", "removeTag:", ["x"]]])
    assert_equal [[:tag_absent, "x"]], exps
  end

  def test_verifiable_expectations_nil_for_location_changing_chain
    # move/archive/delete relocate the .eml — flag verification isn't valid.
    assert_nil M.verifiable_expectations([["read", "markAsRead:", []],
                                          ["archive", "archive:", []]])
    assert_nil M.verifiable_expectations([["move", "moveToMailbox:", ["A"]]])
    assert_nil M.verifiable_expectations([["delete", "deleteMessage:", []]])
  end

  def test_verifiable_expectations_nil_for_clear_tags_mixed_with_tagop
    # Order-dependent net state we don't model — bail rather than false-fail.
    assert_nil M.verifiable_expectations([["clear-tags", "clearTags:", []],
                                          ["tag", "setTag:", ["x"]]])
  end

  def test_verifiable_expectations_clear_tags_alone_is_verifiable
    assert_equal [[:no_user_tags, nil]], M.verifiable_expectations([["clear-tags", "clearTags:", []]])
  end

  def test_verifiable_expectations_nil_when_nothing_observable
    # mute has no clean #flags signal and nothing else is present.
    assert_nil M.verifiable_expectations([["mute", "toggleMuteState:", []]])
  end

  # ---- build_check_ticket (deferred verification) ----

  def test_build_check_ticket_serializes_expectations_as_strings
    ticket = M.build_check_ticket(192784, "<m@x>", [["tag", "setTag:", ["urgent"]]])
    assert_equal 192784, ticket["eml_id"]
    assert_equal "<m@x>", ticket["message_id"]
    assert_equal [["tag_present", "urgent"]], ticket["expectations"]
  end

  def test_build_check_ticket_empty_for_location_changing_chain
    ticket = M.build_check_ticket(1, "<m@x>", [["move", "moveToMailbox:", ["Archive"]]])
    assert_equal [], ticket["expectations"], "moves carry no flag expectations (auto-pass)"
  end

  # ---- flag_expectation_met? predicate ----

  def test_flag_expectation_met_seen
    assert M.flag_expectation_met?(["\\Seen"], :seen, true)
    refute M.flag_expectation_met?([], :seen, true)
    assert M.flag_expectation_met?([], :seen, false)
  end

  def test_flag_expectation_met_tags
    assert M.flag_expectation_met?(["urgent"], :tag_present, "urgent")
    refute M.flag_expectation_met?([], :tag_present, "urgent")
    assert M.flag_expectation_met?(["\\Seen"], :tag_absent, "urgent")
  end

  def test_flag_expectation_met_no_user_tags
    assert M.flag_expectation_met?(["\\Seen", "$Forwarded"], :no_user_tags, nil)
    refute M.flag_expectation_met?(["\\Seen", "keepme"], :no_user_tags, nil)
  end

  # ---- verify_effects: polling success / failure ----

  def test_verify_effects_succeeds_immediately_when_state_matches
    M.stub(:current_flags, ->(_id) { ["\\Seen", "urgent"] }) do
      ok, flags = M.verify_effects(42, [[:seen, true], [:tag_present, "urgent"]], timeout: 0.3)
      assert ok
      assert_equal ["\\Seen", "urgent"], flags
    end
  end

  def test_verify_effects_fails_after_timeout_when_state_never_matches
    calls = 0
    M.stub(:current_flags, ->(_id) { calls += 1; [] }) do
      ok, flags = M.verify_effects(42, [[:flagged, true]], timeout: 0.15, poll: 0.05)
      refute ok
      assert_equal [], flags
      assert_operator calls, :>=, 2, "should have polled more than once before giving up"
    end
  end

  private

  def capture_warn
    orig = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = orig
  end

  def capture_stdout
    orig = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = orig
  end
end
