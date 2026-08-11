# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/search"
require "mail"
require "tmpdir"
require "fileutils"

# Tests for Mailmate::CLI::Search helpers. Each helper is a module method
# reachable directly (the module `extend self`s), so we can test them as
# pure functions against constructed Mail objects and tmpdir IMAP trees.
class TestCliSearch < Minitest::Test
  include Mailmate::TestHelpers

  S = Mailmate::CLI::Search

  # ---- tokenize ----

  def test_tokenize_splits_on_whitespace
    assert_equal %w[a b c], S.tokenize("a b c")
  end

  def test_tokenize_preserves_quoted_phrases
    assert_equal ["a", "b c d", "e"], S.tokenize('a "b c d" e')
  end

  def test_tokenize_handles_unterminated_quote
    # Unterminated quote consumes to end-of-string.
    assert_equal ["x", "rest of line"], S.tokenize('x "rest of line')
  end

  def test_tokenize_empty
    assert_equal [], S.tokenize("")
  end

  def test_tokenize_collapses_extra_whitespace
    assert_equal %w[a b], S.tokenize("a   b")
  end

  # ---- parse_search ----
  #
  # parse_search returns an array of or-groups, each an array of specs.
  # A single-group query is [[spec, ...]].

  def test_parse_search_bare_term_routes_to_message_or_body
    # Post-fix default: bare tokens match MailMate UI's "Common" specifier
    # (headers OR body). See cli/search.rb parse_search.
    specs = S.parse_search("hello")
    assert_equal [[[:message_or_body, "hello", false]]], specs
  end

  def test_parse_search_with_modifier
    specs = S.parse_search("f freron")
    assert_equal [[[:from, "freron", false]]], specs
  end

  def test_parse_search_subject_modifier
    specs = S.parse_search("s digest")
    assert_equal [[[:subject, "digest", false]]], specs
  end

  def test_parse_search_negation_with_modifier
    specs = S.parse_search("f !smith")
    assert_equal [[[:from, "smith", true]]], specs
  end

  def test_parse_search_negation_on_bare_term
    specs = S.parse_search("!spam")
    assert_equal [[[:message_or_body, "spam", true]]], specs
  end

  def test_parse_search_multiple_specs
    specs = S.parse_search("f alice s urgent")
    assert_equal [[[:from, "alice", false], [:subject, "urgent", false]]], specs
  end

  def test_parse_search_modifier_at_end_falls_through
    # A modifier with no following operand becomes a bare term.
    specs = S.parse_search("f")
    assert_equal [[[:message_or_body, "f", false]]], specs
  end

  def test_parse_search_lowercases_terms
    specs = S.parse_search("URGENT")
    assert_equal "urgent", specs.first.first[1]
  end

  # ---- parse_search: or-groups ----

  def test_parse_search_or_splits_groups_and_binds_looser_than_and
    specs = S.parse_search("f bob s invoice or f ann s invoice")
    assert_equal [
      [[:from, "bob", false], [:subject, "invoice", false]],
      [[:from, "ann", false], [:subject, "invoice", false]],
    ], specs
  end

  def test_parse_search_or_group_opening_bare_term_inherits_modifier
    # The app's `d 2024 or 2025 or 2y` shorthand: the modifier in force
    # carries across `or` when the next group opens with a bare term.
    specs = S.parse_search("d 2024 or 2025 or 2y")
    assert_equal [
      [[:date, "2024", false]],
      [[:date, "2025", false]],
      [[:date, "2y", false]],
    ], specs
  end

  def test_parse_search_or_inheritance_uses_last_modifier_in_force
    specs = S.parse_search("f bob d 1h or 2026-08-09")
    assert_equal [
      [[:from, "bob", false], [:date, "1h", false]],
      [[:date, "2026-08-09", false]],
    ], specs
  end

  def test_parse_search_or_only_first_bare_term_inherits
    specs = S.parse_search("d 2024 or 2025 invoice")
    assert_equal [
      [[:date, "2024", false]],
      [[:date, "2025", false], [:message_or_body, "invoice", false]],
    ], specs
  end

  def test_parse_search_quoted_or_is_a_literal_term
    assert_equal [[[:subject, "or", false]]], S.parse_search('s "or"')
    assert_equal [[[:message_or_body, "or", false]]], S.parse_search('"or"')
  end

  def test_parse_search_quoted_group_opener_does_not_inherit
    specs = S.parse_search('d 2024 or "2025"')
    assert_equal [
      [[:date, "2024", false]],
      [[:message_or_body, "2025", false]],
    ], specs
  end

  def test_parse_search_dangling_or_drops_empty_group
    assert_equal [[[:from, "bob", false]]], S.parse_search("f bob or")
    assert_equal [[[:from, "bob", false]]], S.parse_search("or f bob")
    assert_equal [], S.parse_search("or")
  end

  def test_matches_any_or_group_suffices
    mail = make_mail(date: Time.utc(2025, 6, 15, 12))
    hit  = S.order_specs(S.parse_search("f a@b.com or f nobody"))
    miss = S.order_specs(S.parse_search("f nobody or f also-nobody"))
    assert S.matches?(mail, nil, hit, true)
    refute S.matches?(mail, nil, miss, true)
  end

  # ---- state specs (is:/has:) ----

  def test_parse_search_state_specs_are_native
    assert_equal [[[:state, "is:unread", false]]], S.parse_search("is:unread")
    assert_equal [[[:state, "is:unread", true]]],  S.parse_search("!is:unread")
    assert_equal [[[:state, "is:unread", true]]],  S.parse_search("-is:unread")
    assert_equal [[[:state, "has:attachment", false]]], S.parse_search("has:attachment")
    # Quoted stays a literal Common-specifier term.
    assert_equal [[[:message_or_body, "is:unread", false]]], S.parse_search('"is:unread"')
  end

  FLAG_MAP = {
    1 => [],                        # unread, unflagged
    2 => ["\\Seen"],                # read
    3 => ["\\Seen", "\\Flagged"],   # read + flagged
    4 => ["\\Seen", "\\Answered"],  # replied
  }.freeze
  CT_MAP = {
    1 => "multipart/mixed; boundary=x",
    2 => "multipart/alternative; boundary=y",
  }.freeze

  FakeFlagsReader = Struct.new(:x) do
    def flags_for(id) = FLAG_MAP.fetch(id, [])
  end
  FakeCtReader = Struct.new(:x) do
    def value_for(id) = CT_MAP[id]
  end

  def with_state_readers(&blk)
    readers = { "#flags" => FakeFlagsReader.new, "content-type" => FakeCtReader.new }
    S.stub(:reader_for, ->(name) { readers[name] }, &blk)
  end

  def test_state_specs_match_flags_and_attachment_layout
    with_state_readers do
      unread = S.parse_search("is:unread")
      assert S.matches?(nil, "1", unread, true)
      refute S.matches?(nil, "2", unread, true)
      assert S.matches?(nil, "2", S.parse_search("is:read"), true)
      assert S.matches?(nil, "3", S.parse_search("is:flagged"), true)
      assert S.matches?(nil, "3", S.parse_search("is:starred"), true) # gmail synonym
      refute S.matches?(nil, "2", S.parse_search("is:flagged"), true)
      assert S.matches?(nil, "4", S.parse_search("is:replied"), true)
      assert S.matches?(nil, "1", S.parse_search("has:attachment"), true)
      refute S.matches?(nil, "2", S.parse_search("has:attachment"), true)
      # Negation, both spellings.
      refute S.matches?(nil, "1", S.parse_search("!is:unread"), true)
      assert S.matches?(nil, "2", S.parse_search("-is:unread"), true)
    end
  end

  def test_date_spec_error_flags_unknown_state_values
    err = S.date_spec_error(S.parse_search("is:snoozed").first)
    assert_includes err, "is:snoozed"
    assert_includes err, "is:unread"
    assert_nil S.date_spec_error(S.parse_search("is:unread has:attachment d 7d").first)
  end

  # ---- date_matches? ----

  def make_mail(date:)
    Mail.new do
      from "a@b.com"; to "c@d.com"; subject "x"; date date.rfc2822
    end
  end

  # Absolute-date fixtures use noon UTC: matching converts to the display
  # zone (same as the date/time output columns), and noon lands on the same
  # calendar day in any test-runner zone within ±11 hours of UTC — midnight
  # would shift a day west of Greenwich.
  def test_date_matches_year_only
    mail = make_mail(date: Time.utc(2025, 6, 15, 12))
    assert S.date_matches?(mail, nil, "2025")
    refute S.date_matches?(mail, nil, "2024")
  end

  def test_date_matches_year_month
    mail = make_mail(date: Time.utc(2025, 6, 15, 12))
    assert S.date_matches?(mail, nil, "2025-06")
    refute S.date_matches?(mail, nil, "2025-07")
  end

  def test_date_matches_full_date
    mail = make_mail(date: Time.utc(2025, 6, 15, 12))
    assert S.date_matches?(mail, nil, "2025-06-15")
    refute S.date_matches?(mail, nil, "2025-06-16")
  end

  def test_date_matches_slash_dates_month_first_by_default
    mail = make_mail(date: Time.utc(2025, 6, 15, 12))
    assert S.date_matches?(mail, nil, "6/15/2025")
    assert S.date_matches?(mail, nil, "6/2025")
    refute S.date_matches?(mail, nil, "7/15/2025")
    # 15/6/2025 is month 15 under M/D/Y — an invalid date, not a match.
    refute S.date_matches?(mail, nil, "15/6/2025")
  end

  def test_date_matches_slash_dates_day_first_when_european
    S.date_order = :dmy
    mail = make_mail(date: Time.utc(2025, 6, 15, 12))
    assert S.date_matches?(mail, nil, "15/6/2025")
    refute S.date_matches?(mail, nil, "15/7/2025")
  ensure
    S.date_order = :mdy
  end

  def test_date_order_flip_resets_the_range_memo
    mail = make_mail(date: Time.utc(2025, 3, 5, 12))
    S.date_order = :mdy
    assert S.date_matches?(mail, nil, "3/5/2025")  # March 5 (memoized)
    S.date_order = :dmy
    refute S.date_matches?(mail, nil, "3/5/2025")  # now May 3
  ensure
    S.date_order = :mdy
  end

  def test_date_spec_error_flags_impossible_calendar_dates
    ["d 2026-02-31", "d 2026-13", "d 2026-13-05"].each do |q|
      err = S.date_spec_error(S.parse_search(q).first)
      refute_nil err, "expected #{q.inspect} to error"
      assert_includes err, "cannot match"
    end
  end

  def test_date_spec_error_hints_at_day_first_ordering
    err = S.date_spec_error(S.parse_search("d 13/8/2026").first)
    assert_includes err, "--european"
  end

  def test_date_matches_day_in_display_zone_not_senders
    # 2am UTC is the previous evening anywhere west of UTC. Whatever day
    # localize says a message displays under is the day a search must find
    # it under — sender-local and display day differ for this instant in
    # most zones, and the display day wins.
    t = Time.utc(2025, 6, 15, 2)
    display_day = Mailmate.localize(t).strftime("%Y-%m-%d")
    assert S.date_matches?(make_mail(date: t), nil, display_day)
  end

  def test_date_matches_relative_days
    # `1d` = today only; `2d` = yesterday and today; `10d` reaches back 9.
    assert S.date_matches?(make_mail(date: Time.now), nil, "1d")
    five_days = make_mail(date: Time.now - 5 * 86_400)
    assert S.date_matches?(five_days, nil, "10d")
    refute S.date_matches?(five_days, nil, "5d")
    assert S.date_matches?(five_days, nil, "6d")
    refute S.date_matches?(five_days, nil, "1d")
  end

  def test_date_matches_hour_window_is_rolling
    assert S.date_matches?(make_mail(date: Time.now - 1800), nil, "1h")
    two_hours = make_mail(date: Time.now - 2 * 3600)
    refute S.date_matches?(two_hours, nil, "1h")
    assert S.date_matches?(two_hours, nil, "24h")
    assert S.date_matches?(two_hours, nil, "<1h") # older than the 1h window
  end

  def test_date_matches_relative_weeks_months_years
    one_year_ago = (Date.today << 12).to_time
    mail = make_mail(date: one_year_ago + 86_400) # one day inside the year window
    assert S.date_matches?(mail, nil, "1y")
    assert S.date_matches?(mail, nil, "12m")
    assert S.date_matches?(mail, nil, "53w")
  end

  def test_date_matches_invalid_term_returns_false
    mail = make_mail(date: Time.now)
    refute S.date_matches?(mail, nil, "not-a-date")
  end

  def test_date_matches_comparisons_on_month
    june = make_mail(date: Time.utc(2025, 6, 15, 12))
    assert S.date_matches?(june, nil, ">2025-05")
    refute S.date_matches?(june, nil, ">2025-06")   # > excludes the period
    assert S.date_matches?(june, nil, ">=2025-06")
    assert S.date_matches?(june, nil, "<2025-07")
    refute S.date_matches?(june, nil, "<2025-06")   # < excludes the period
    assert S.date_matches?(june, nil, "<=2025-06")
    refute S.date_matches?(june, nil, "<=2025-05")
  end

  def test_date_matches_comparisons_on_day_and_year
    mail = make_mail(date: Time.utc(2025, 6, 15, 12))
    assert S.date_matches?(mail, nil, ">2025-06-14")
    refute S.date_matches?(mail, nil, ">2025-06-15")
    assert S.date_matches?(mail, nil, "<2026")
    refute S.date_matches?(mail, nil, "<2025")
  end

  def test_date_matches_comparison_on_relative_window
    old = make_mail(date: Time.now - 5 * 86_400)
    # `<3d` = before the 3-day window opens — same set as `d !3d`.
    assert S.date_matches?(old, nil, "<3d")
    refute S.date_matches?(make_mail(date: Time.now), nil, "<3d")
  end

  # ---- date_spec_error ----

  def test_date_spec_error_flags_empty_intersection
    specs = S.parse_search("d >2026 d <2025").first
    err = S.date_spec_error(specs)
    assert_includes err, "impossible date range"
    assert_includes err, "d >2026"
    assert_includes err, "d <2025"
  end

  def test_date_spec_error_flags_a_term_that_cannot_match
    # Nothing is after a window that already extends to the future, and a
    # zero-length window contains nothing.
    ["d >3d", "d >1h", "d 0d", "d 0h"].each do |q|
      err = S.date_spec_error(S.parse_search(q).first)
      refute_nil err, "expected #{q.inspect} to error"
      assert_includes err, "cannot match"
    end
  end

  def test_date_spec_error_accepts_valid_combinations
    assert_nil S.date_spec_error(S.parse_search("d >=2026-05 d <2026-08").first)
    assert_nil S.date_spec_error(S.parse_search("d 2026 d 2026-05").first)
    assert_nil S.date_spec_error(S.parse_search("f bob s invoice").first)
    assert_nil S.date_spec_error(S.parse_search("d 24h").first)
    # Negated windows subtract, not intersect — never "impossible".
    assert_nil S.date_spec_error(S.parse_search("d 2y d !3d").first)
    # Day and hour windows are different scales; no cross-family check.
    assert_nil S.date_spec_error(S.parse_search("d 24h d 2026").first)
  end

  # ---- exclude_quoted threading ----

  def test_body_value_threads_exclude_quoted_through_to_body_index_records
    seen = []
    stub_records = lambda do |eml_id, exclude_quoted: false|
      seen << exclude_quoted
      exclude_quoted ? ["unquoted only"] : ["unquoted text", "quoted text"]
    end
    S.stub(:body_index_records, stub_records) do
      v_default  = S.body_value("42", nil, nil)
      v_excluded = S.body_value("42", nil, nil, exclude_quoted: true)

      assert_includes v_default,  "quoted text"
      refute_includes v_excluded, "quoted text"
      assert_equal [false, true], seen
    end
  end

  def test_matches_body_threads_exclude_quoted_through_to_body_matching
    seen = []
    stub_records = lambda do |_eml_id, exclude_quoted: false|
      seen << exclude_quoted
      exclude_quoted ? ["clean body"] : ["clean body", "forwarded: junk"]
    end
    # body_candidates → nil forces the per-message body_index_records path
    # (the no-body-indexes fallback) so the stub below is authoritative.
    S.stub(:body_candidates, nil) do
      S.stub(:body_index_records, stub_records) do
        assert S.matches?(nil, "42", [[[:body, "junk", false]]], false, "/nope", index_only: true)
        refute S.matches?(nil, "42", [[[:body, "junk", false]]], false, "/nope", index_only: true, exclude_quoted: true)
      end
    end
    assert_equal [false, true], seen
  end

  # ---- body_value (index-first body matching) ----

  def test_body_value_prefers_unquoted_and_quoted_indexes
    # When MailMate has body-indexed the message, body_value uses
    # #unquoted#lc + #quoted#lc records — no .eml read needed. body_value
    # joins all returned segments with " ".
    S.stub(:body_index_records, ["hello there world", "previously: hi"]) do
      v = S.body_value("42", nil, nil)
      assert_includes v, "hello there world"
      assert_includes v, "previously: hi"
    end
  end

  def test_body_value_falls_back_to_mail_when_no_index_record
    # Index has no records — fall back to text_body(mail).
    S.stub(:body_index_records, []) do
      mail = Mail.new { from "a@b"; to "c@d"; subject "s"; date Time.now.rfc2822; body "Hello FROM Mail." }
      assert_includes S.body_value("42", mail, nil), "hello from mail."
    end
  end

  def test_body_value_lazily_reads_eml_when_no_index_no_mail
    # The miss-with-no-mail case: lazily Mail.read the .eml. Construct a real
    # .eml on disk so the load actually returns content.
    Dir.mktmpdir do |dir|
      eml = File.join(dir, "1.eml")
      File.write(eml, "From: a@b\nTo: c@d\nSubject: s\nDate: #{Time.now.rfc2822}\n\nLAZY BODY CONTENT")
      S.stub(:body_index_records, []) do
        assert_includes S.body_value("42", nil, eml), "lazy body content"
      end
    end
  end

  def test_body_value_returns_empty_when_no_index_no_mail_no_path
    S.stub(:body_index_records, []) do
      assert_equal "", S.body_value("42", nil, nil)
    end
  end

  # ---- matches? :body (per-message fallback path) ----

  def test_matches_body_uses_index_when_present
    # Specifically exercises the index-tier matches?(nil, eml_id, …, path) path
    # so we know body filters work with no preloaded mail.
    S.stub(:body_candidates, nil) do
      S.stub(:body_index_records, ["needle in haystack"]) do
        assert S.matches?(nil, "42", [[[:body, "needle", false]]], false, "/nope.eml")
        refute S.matches?(nil, "42", [[[:body, "missing", false]]], false, "/nope.eml")
      end
    end
  end

  def test_matches_body_respects_headers_only_short_circuit
    # headers_only=true means body matchers always fail without touching the index/mail.
    refute S.matches?(nil, "42", [[[:body, "anything", false]]], true, "/nope.eml")
  end

  # ---- --index-only short-circuits the fallback ----

  def test_body_value_index_only_skips_mail_fallback
    # Index has nothing; with index_only:true the helper must NOT fall back to
    # the parsed mail (which would otherwise have provided a match).
    S.stub(:body_index_records, []) do
      mail = Mail.new { from "a@b"; to "c@d"; subject "s"; date Time.now.rfc2822; body "matchable body content" }
      assert_equal "", S.body_value("42", mail, nil, index_only: true)
      # Sanity: same call without index_only DOES fall back and find the content.
      assert_includes S.body_value("42", mail, nil), "matchable body content"
    end
  end

  def test_body_value_index_only_skips_lazy_eml_read
    # Even with a real path to an .eml on disk, index_only must not crack it open.
    Dir.mktmpdir do |dir|
      eml = File.join(dir, "1.eml")
      File.write(eml, "From: a@b\nTo: c@d\nSubject: s\nDate: #{Time.now.rfc2822}\n\nBODY ON DISK")
      S.stub(:body_index_records, []) do
        assert_equal "", S.body_value("42", nil, eml, index_only: true)
        # Sanity: without index_only, the lazy Mail.read finds the body.
        assert_includes S.body_value("42", nil, eml), "body on disk"
      end
    end
  end

  def test_matches_body_with_index_only_finds_indexed_message
    S.stub(:body_candidates, nil) do
      S.stub(:body_index_records, ["found this in the index"]) do
        assert S.matches?(nil, "42", [[[:body, "found this", false]]], false, "/nope.eml", index_only: true)
      end
    end
  end

  def test_matches_body_with_index_only_misses_unindexed_message
    # No index record + index_only:true → no match, even though a real .eml
    # on disk would otherwise yield the content.
    Dir.mktmpdir do |dir|
      eml = File.join(dir, "1.eml")
      File.write(eml, "From: a@b\nSubject: s\nDate: #{Time.now.rfc2822}\n\nWOULD HAVE MATCHED")
      S.stub(:body_candidates, nil) do
        S.stub(:body_index_records, []) do
          refute S.matches?(nil, "42", [[[:body, "would have matched", false]]], false, eml, index_only: true)
          # Same query without index_only DOES find it via the lazy fallback.
          assert S.matches?(nil, "42", [[[:body, "would have matched", false]]], false, eml)
        end
      end
    end
  end

  # ---- matches? :body (inverted candidate path) ----

  def test_body_matches_uses_candidate_set_when_available
    cands = { 42 => true }
    S.stub(:body_candidates, cands) do
      assert S.body_matches?("42", nil, nil, "x", "x".b, index_only: true)
      refute S.body_matches?("99", nil, nil, "x", "x".b, index_only: true)
    end
  end

  def test_body_matches_indexed_non_candidate_is_definitive_miss
    # Body-indexed but not in the candidate set → real non-match; even the
    # --all mode (index_only: false) must NOT crack open the .eml.
    Dir.mktmpdir do |dir|
      eml = File.join(dir, "1.eml")
      File.write(eml, "From: a@b\nSubject: s\nDate: #{Time.now.rfc2822}\n\nWOULD HAVE MATCHED")
      S.stub(:body_candidates, {}) do
        S.stub(:body_indexed?, true) do
          refute S.body_matches?("42", nil, eml, "would have matched", "would have matched".b)
        end
      end
    end
  end

  def test_body_matches_unindexed_falls_back_to_eml_under_all
    # Not body-indexed at all → --all mode reads the .eml; index_only
    # (the default mode) still misses.
    Dir.mktmpdir do |dir|
      eml = File.join(dir, "1.eml")
      File.write(eml, "From: a@b\nSubject: s\nDate: #{Time.now.rfc2822}\n\nWOULD HAVE MATCHED")
      S.stub(:body_candidates, {}) do
        S.stub(:body_indexed?, false) do
          assert S.body_matches?("42", nil, eml, "would have matched", "would have matched".b)
          refute S.body_matches?("42", nil, eml, "would have matched", "would have matched".b, index_only: true)
        end
      end
    end
  end

  # ---- field_value ----

  # field_value(eml_id, mail, field) — index-first with mail fallback.
  # Passing eml_id=nil forces the mail-only path, which is what these
  # in-memory fixtures exercise.

  def test_field_value_from
    mail = Mail.new { from "Alice <alice@example.com>"; to "x@y"; subject "s"; date Time.now.rfc2822 }
    v = S.field_value(nil, mail, :from)
    assert_includes v, "alice@example.com"
  end

  def test_field_value_recipients_combines_to_and_cc
    mail = Mail.new { from "a@b"; to "to@x.com"; cc "cc@x.com"; subject "s"; date Time.now.rfc2822 }
    v = S.field_value(nil, mail, :recipients)
    assert_includes v, "to@x.com"
    assert_includes v, "cc@x.com"
  end

  def test_field_value_subject_downcased
    mail = Mail.new { from "a@b"; to "c@d"; subject "URGENT"; date Time.now.rfc2822 }
    assert_equal "urgent", S.field_value(nil, mail, :subject)
  end

  def test_field_value_address_any
    mail = Mail.new do
      from "a@b.com"; to "c@d.com"; subject "x"; date Time.now.rfc2822
    end
    v = S.field_value(nil, mail, :address_any)
    assert_includes v, "a@b.com"
    assert_includes v, "c@d.com"
  end

  def test_field_value_prefers_index_over_mail
    # When the index has a value, that's what we substring-match against —
    # the mail object is ignored. Lets us match without ever opening the .eml.
    S.stub(:header_index_value_lc, ->(_eml_id, name) { name == "subject" ? "from the index" : nil }) do
      mail = Mail.new { from "a@b"; to "c@d"; subject "from-the-mail"; date Time.now.rfc2822 }
      assert_equal "from the index", S.field_value("99", mail, :subject)
    end
  end

  # ---- outbound? ----

  def test_outbound_by_path_sent
    mail = Mail.new { from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822 }
    assert S.outbound?("/imap/acct1.imap/Sent Messages.mailbox/Messages/1.eml", mail)
  end

  def test_outbound_by_path_drafts
    mail = Mail.new { from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822 }
    assert S.outbound?("/imap/acct1.imap/Drafts.mailbox/Messages/1.eml", mail)
  end

  def test_outbound_by_identity_when_path_neutral
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com" }) do
      mail = Mail.new { from "me@example.com"; to "x@y"; subject "x"; date Time.now.rfc2822 }
      assert S.outbound?("/imap/acct1.imap/INBOX.mailbox/Messages/1.eml", mail)
    end
  end

  def test_outbound_false_when_neither
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com" }) do
      mail = Mail.new { from "other@example.com"; to "x@y"; subject "x"; date Time.now.rfc2822 }
      refute S.outbound?("/imap/acct1.imap/INBOX.mailbox/Messages/1.eml", mail)
    end
  end

  # ---- party_for ----

  # party_for now takes (eml_id, mail, outbound) — eml_id is used to read
  # to/cc/from from MailMate's per-header indexes before falling back to
  # the Mail object. nil eml_id forces the mail-only path, which is what
  # these in-memory fixtures exercise.

  def test_party_for_inbound_shows_from
    mail = Mail.new { from "alice@example.com"; to "me@example.com"; subject "x"; date Time.now.rfc2822 }
    assert_equal "alice@example.com", S.party_for(nil, mail, false)
  end

  def test_party_for_outbound_filters_my_addresses
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com",
                       "MAILMATE_APP_SUPPORT_DIR" => "/nonexistent-mailmate-for-tests" }) do
      mail = Mail.new do
        from "me@example.com"
        to ["me@example.com", "client@example.com"]
        subject "x"; date Time.now.rfc2822
      end
      result = S.party_for(nil, mail, true)
      assert_includes result, "client@example.com"
      refute_includes result, "me@example.com"
    end
  end

  def test_party_for_outbound_falls_back_when_only_me
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com",
                       "MAILMATE_APP_SUPPORT_DIR" => "/nonexistent-mailmate-for-tests" }) do
      mail = Mail.new do
        from "me@example.com"; to "me@example.com"; subject "x"; date Time.now.rfc2822
      end
      # Self-sent — fallback shows the raw to: even if it's me.
      result = S.party_for(nil, mail, true)
      assert_includes result, "me@example.com"
    end
  end

  # ---- extract ----

  def test_extract_id
    mail = Mail.new { from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822 }
    assert_equal "42", S.extract("id", "42", "/path", mail)
  end

  def test_extract_path
    mail = Mail.new { from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822 }
    assert_equal "/p/to/1.eml", S.extract("path", "1", "/p/to/1.eml", mail)
  end

  # Scope app_support_dir to a nonexistent path so the per-header indexes
  # aren't available — extract falls back to the mail object, which is what
  # these tests are actually exercising.
  def with_no_indexes(&block)
    with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => "/nonexistent-mailmate-for-tests" }, &block)
  end

  def test_extract_subject
    with_no_indexes do
      mail = Mail.new { from "a@b"; to "c@d"; subject "Hello"; date Time.now.rfc2822 }
      assert_equal "Hello", S.extract("subject", "1", "/p", mail)
    end
  end

  def test_extract_from
    with_no_indexes do
      mail = Mail.new { from "alice@example.com"; to "c@d"; subject "x"; date Time.now.rfc2822 }
      assert_equal "alice@example.com", S.extract("from", "1", "/p", mail)
    end
  end

  def test_extract_to
    with_no_indexes do
      mail = Mail.new { from "a@b"; to "bob@x.com"; subject "x"; date Time.now.rfc2822 }
      assert_equal "bob@x.com", S.extract("to", "1", "/p", mail)
    end
  end

  # ---- index-first behavior (new) ----

  def test_extract_prefers_index_value_over_mail
    fake_index = { "subject" => "From-Index", "from" => "Alice <alice@example.com>" }
    S.stub(:header_index_value, ->(_eml_id, name) { fake_index[name] }) do
      mail = Mail.new { from "ignored@example.com"; to "x@y"; subject "From-Mail"; date Time.now.rfc2822 }
      assert_equal "From-Index", S.extract("subject", "1", "/p", mail),
        "subject should come from the index when present"
      assert_equal "Alice <alice@example.com>", S.extract("from", "1", "/p", mail),
        "from should come from the index (preserves Display Name <addr>) when present"
    end
  end

  def test_extract_falls_back_to_mail_when_index_blank
    # Empty string from the index counts as "no value" — fall back to mail.
    S.stub(:header_index_value, ->(_eml_id, _name) { "" }) do
      mail = Mail.new { from "fallback@example.com"; to "c@d"; subject "Fallback"; date Time.now.rfc2822 }
      assert_equal "Fallback", S.extract("subject", "1", "/p", mail)
      assert_equal "fallback@example.com", S.extract("from", "1", "/p", mail)
    end
  end

  def test_extract_date_from_mail
    # Scope config to a tmpdir with no #date index so extract falls back to
    # mail.date instead of the real MailMate index. Pin display_timezone to
    # UTC so the assertion holds regardless of the host's local zone — the
    # date and time fields run mail.date through Mailmate.localize.
    Dir.mktmpdir do |dir|
      with_config(env: {
        "MAILMATE_APP_SUPPORT_DIR" => dir,
        "MAILMATE_DISPLAY_TIMEZONE" => "+00:00",
      }) do
        mail = Mail.new { from "a@b"; to "c@d"; subject "x"; date Time.utc(2025, 7, 4).rfc2822 }
        assert_equal "2025-07-04", S.extract("date", "1", "/p", mail)
      end
    end
  end

  def test_extract_direction_inbound
    # The outbound check consults the from header — point at a nonexistent
    # app-support dir so it falls back to mail.from instead of the real index.
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com",
                       "MAILMATE_APP_SUPPORT_DIR" => "/nonexistent-mailmate-for-tests" }) do
      mail = Mail.new { from "a@b"; to "me@example.com"; subject "x"; date Time.now.rfc2822 }
      assert_equal "←", S.extract("direction", "1", "/imap/acct/INBOX.mailbox/Messages/1.eml", mail)
    end
  end

  def test_extract_direction_outbound
    with_config(env: { "MAILMATE_IDENTITIES" => "me@example.com" }) do
      mail = Mail.new { from "me@example.com"; to "x@y"; subject "x"; date Time.now.rfc2822 }
      assert_equal "→", S.extract("direction", "1", "/imap/acct/Sent Messages.mailbox/Messages/1.eml", mail)
    end
  end

  def test_extract_archive_flag
    mail = Mail.new { from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822 }
    assert_equal "A", S.extract("archive", "1", "/imap/acct/Archive.mailbox/Messages/1.eml", mail)
    assert_equal "P", S.extract("archive", "1", "/imap/acct/INBOX.mailbox/Messages/1.eml", mail)
  end

  # ---- fields_tier ----

  def test_fields_tier_index_only
    assert_equal :index, S.fields_tier(%w[id path date time])
  end

  def test_fields_tier_index_when_subject_present
    # subject and the other header-tier output fields now read from MailMate's
    # per-header index, so they no longer force a .eml read.
    assert_equal :index, S.fields_tier(%w[id subject])
  end

  def test_fields_tier_index_for_all_migrated_header_fields
    assert_equal :index, S.fields_tier(%w[id from to cc bcc reply-to subject
                                          message-id message-url references in-reply-to
                                          direction party])
  end

  def test_fields_tier_header_default_for_unknown_field
    # Unknown fields default to :header (the safe tier).
    assert_equal :header, S.fields_tier(%w[id unknown-field])
  end

  # ---- resolve_account ----

  def test_resolve_account_direct_match
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "Messages.noindex", "IMAP", "acct1.imap"))
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        assert_equal "acct1.imap", S.resolve_account("acct1.imap")
      end
    end
  end

  def test_resolve_account_email_with_at_sign
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "Messages.noindex", "IMAP", "brian%40example.com@imap.example.com"))
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        # `@` is URL-encoded to %40; the user passes the plain email.
        assert_equal "brian%40example.com@imap.example.com", S.resolve_account("brian@example.com")
      end
    end
  end

  def test_resolve_account_unknown
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "Messages.noindex", "IMAP"))
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        assert_nil S.resolve_account("nonexistent")
      end
    end
  end

  # ---- resolve_mailbox ----

  def test_resolve_mailbox_all
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "Messages.noindex", "IMAP", "acct1.imap", "INBOX.mailbox", "Messages"))
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        dirs, filters = S.resolve_mailbox("all")
        refute_empty dirs
        assert_empty filters
      end
    end
  end

  def test_resolve_mailbox_account_path
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "Messages.noindex", "IMAP", "acct1.imap", "INBOX.mailbox", "Messages"))
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        dirs, _ = S.resolve_mailbox("acct1.imap/INBOX")
        assert_equal 1, dirs.size
        assert dirs.first.end_with?("INBOX.mailbox/Messages")
      end
    end
  end

  def test_resolve_mailbox_name_lookup
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "Messages.noindex", "IMAP", "acct1.imap", "INBOX.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(dir, "Messages.noindex", "IMAP", "acct2.imap", "INBOX.mailbox", "Messages"))
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        dirs, _ = S.resolve_mailbox("INBOX")
        assert_equal 2, dirs.size
      end
    end
  end

  # ---- prefilter_pass? ----
  #
  # The header-block prefilter no longer runs for spec matching — filter
  # modifiers now go through MailMate's per-header indexes directly. The
  # prefilter only kicks in for smart-mailbox filters with header literals.

  def test_prefilter_pass_is_noop_without_smart_literals
    # No path read, no exception — returns true unconditionally when there
    # are no smart-mailbox literals to check, regardless of specs.
    assert S.prefilter_pass?("/nonexistent.eml", [[:from, "alice", false]])
    assert S.prefilter_pass?("/nonexistent.eml", [[:body, "anything", false]])
    assert S.prefilter_pass?("/nonexistent.eml", [])
  end
end
