# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/mcp"

# Mailmate::SearchSyntax is the single source both `mmsearch --help` and the
# MCP `search` description render from, plus the detector that breaks the
# silent-empty-result failure: a query in another mail system's dialect
# (`date:today`) is a VALID quicksearch for that literal text, so it returns
# zero rows with no error and the caller believes the mailbox is empty.
class TestSearchSyntax < Minitest::Test
  S = Mailmate::SearchSyntax

  # ---- reference rendering -------------------------------------------------

  def test_reference_covers_every_modifier_and_example
    ref = S.reference
    S::MODIFIERS.each { |spec, meaning| assert_includes ref, spec; assert_includes ref, meaning }
    S::EXAMPLES.each  { |query, _| assert_includes ref, query }
  end

  def test_reference_indents_every_line_for_embedding
    S.reference(indent: "    ").lines.reject { |l| l.strip.empty? }.each do |line|
      assert line.start_with?("    "), "unindented line in reference: #{line.inspect}"
    end
  end

  # Both surfaces must render from this module — the drift these tests exist
  # to prevent is a modifier added here and forgotten in the other place.
  def test_cli_help_and_mcp_description_share_the_reference
    # Built, not run: `run` would reach the first-run config bootstrap, which
    # blocks on stdin under a test harness.
    help = Mailmate::CLI::Search.send(:build_parser, {}).to_s
    mcp  = Mailmate::MCP::TOOLS.find { |t| t[:name] == "search" }[:description]
    sample = S::MODIFIERS.first.first
    assert_includes help, sample
    assert_includes mcp,  sample
    assert_includes help, "d 2026-08-10"
    assert_includes mcp,  "d 2026-08-10"
  end

  # ---- foreign-syntax detection --------------------------------------------

  def test_detects_the_dialects_agents_actually_guess
    { "date:today"            => "date",
      "date:8/10/2026-today"  => "date",
      "after:8am"             => "after",
      "from:bob@example.com"  => "from",
      "subject:invoice"       => "subject",
      "newer_than:2d"         => "newer_than" }.each do |query, key|
      tokens = S.foreign_tokens(query)
      refute_empty tokens, "expected #{query.inspect} to be flagged"
      assert_equal key, tokens.first.last
    end
  end

  def test_leaves_valid_quicksearch_alone
    ["d 1d", "f substack d 7d", "s \"invoice due\" !draft", "d 2026-08-10",
     "T urgent", "m acme d 60d", "f !smith", ""].each do |query|
      assert_empty S.foreign_tokens(query), "false positive on #{query.inspect}"
    end
  end

  def test_ignores_colons_inside_quoted_terms
    # A deliberate hunt for the literal string is not a mistake.
    assert_empty S.foreign_tokens('s "date:today"')
    assert_empty S.foreign_tokens("b 'from:bob'")
  end

  def test_ignores_colons_that_are_not_foreign_keys
    assert_empty S.foreign_tokens("s re:launch")
    assert_empty S.foreign_tokens("b http://example.com")
  end

  def test_reports_each_distinct_key_once
    tokens = S.foreign_tokens("date:today after:8am date:yesterday")
    assert_equal %w[date after], tokens.map(&:last)
  end

  # ---- the advisory --------------------------------------------------------

  def test_hint_names_the_token_and_the_equivalent
    hint = S.zero_result_hint("date:today")
    assert_includes hint, "date:today"
    assert_includes hint, "d <date>"
    assert_includes hint, "mmsearch --help"
  end

  def test_hint_is_silent_for_an_ordinary_empty_result
    # Polling for mail that has not arrived is normal and correct — an empty
    # result there must stay quiet, or the advisory becomes noise.
    assert_nil S.zero_result_hint("d 1h")
    assert_nil S.zero_result_hint("f OrderShipped d 1d")
    assert_nil S.zero_result_hint("")
  end

  def test_hint_handles_a_key_with_no_known_equivalent
    hint = S.zero_result_hint("in:inbox")
    assert_includes hint, "in:inbox"
    assert_includes hint, "mmsearch --help"
  end

  # ---- translation ---------------------------------------------------------

  TODAY = Date.new(2026, 8, 11)

  def translated(query)
    S.translate(query, today: TODAY).first
  end

  def test_translates_header_keys
    assert_equal "f bob@example.com", translated("from:bob@example.com")
    assert_equal "t ann", translated("to:ann")
    assert_equal "c ann", translated("cc:ann")
    assert_equal "s invoice", translated("subject:invoice")
    assert_equal "b unsubscribe", translated("body:unsubscribe")
    assert_equal "T urgent", translated("label:urgent")
  end

  def test_translates_quoted_and_negated_header_values
    assert_equal "s \"invoice due\"", translated('subject:"invoice due"')
    assert_equal "f !smith", translated("-from:smith")
    assert_equal "f !smith", translated("!from:smith")
    # `f !"a b"` would not tokenize — a negated multi-word value stays put.
    assert_equal '-subject:"a b"', translated('-subject:"a b"')
  end

  def test_translates_date_keywords_and_formats
    assert_equal "d 1d", translated("date:today")
    assert_equal "d 2026-08-10", translated("date:yesterday")
    assert_equal "d 2026-03-05", translated("date:2026-03-05")
    assert_equal "d 2026-03-05", translated("date:3/5/2026")
    assert_equal "d 2026-03-05", translated("date:2026/3/5")
    assert_equal "d 2026-05", translated("date:2026/5")
    assert_equal "d 2026", translated("date:2026")
    assert_equal "d 7d", translated("date:7d")
    assert_equal "d 1d", translated("received:today")
    assert_equal "d 1d", translated("on:today")
  end

  def test_translates_range_ending_today_as_after_window
    # Seen verbatim in real transcripts.
    assert_equal "d >=2026-08-10", translated("date:8/10/2026-today")
  end

  def test_translates_absolute_ranges_as_inclusive_comparison_pairs
    # The 2026-08-13 dogfood query shape: two dash-separated slash dates.
    assert_equal "d >=2026-08-13 d <=2026-08-14", translated("date:8/13/2026-8/14/2026")
    # ISO sides carry hyphens of their own — the separator must be found
    # among them, not assumed to be the first dash.
    assert_equal "d >=2026-08-13 d <=2026-08-14", translated("date:2026-08-13-2026-08-14")
    assert_equal "d >=2026-08-13 d <=2026-08-14", translated("date:2026-08-13..2026-08-14")
    assert_equal "d >=2026-05 d <=2026-07", translated("date:2026-05-2026-07")
    assert_equal "d >=2026 d <=2027", translated("date:2026-2027")
  end

  def test_range_with_keyword_bounds
    assert_equal "d >=2026-08-10 d <=2026-08-11", translated("date:yesterday..today")
  end

  def test_leaves_unparseable_ranges_alone
    ["date:next-week", "date:8am-5pm", "date:8/13/2026-forever"].each do |q|
      assert_equal q, translated(q), "expected #{q.inspect} unchanged"
    end
  end

  # MailMate's own attribute heads, minus the '#'. The 2026-08-13 dogfood
  # failure: `date-received:8/13/2026-8/14/2026` matched the KEY nowhere, so
  # neither translation nor the zero-result advisory fired — zero rows,
  # believed. Aliases route compounds through the same pipeline as their base.
  def test_translates_mailmate_head_aliases
    assert_equal "d 2026-08-13", translated("date-received:8/13/2026")
    assert_equal "d 2026-08-13", translated("date_received:2026-08-13")
    assert_equal "d 2026-08-13", translated("received-date:8/13/2026")
    assert_equal "d 2026-08-13", translated("date-sent:8/13/2026")
    assert_equal "d 2026-08-13", translated("Date-Received:8/13/2026")
    # The exact query from the dogfood transcript, end to end.
    assert_equal "d >=2026-08-13 d <=2026-08-14",
                 translated("date-received:8/13/2026-8/14/2026")
  end

  def test_flags_untranslatable_values_on_mailmate_heads
    hint = S.zero_result_hint("date-received:8am")
    assert_includes hint, "date-received:8am"
    assert_includes hint, "d <date>"
  end

  def test_flags_date_last_viewed_without_translating
    # Viewed ≠ received — no faithful `d` equivalent, so it must be flagged
    # (no silence) but never rewritten (no wrong guess).
    assert_equal "date-last-viewed:2026-08-13", translated("date-last-viewed:2026-08-13")
    hint = S.zero_result_hint("date-last-viewed:2026-08-13")
    assert_includes hint, "date-last-viewed"
  end

  def test_translates_day_first_slash_dates_when_european
    assert_equal "d 2026-08-09", S.translate("date:9/8/2026", today: TODAY, european: true).first
    assert_equal "d <2026-08-09", S.translate("before:9/8/2026", today: TODAY, european: true).first
  end

  def test_translates_after_before_until_as_comparisons
    assert_equal "d >=2026-08-01", translated("after:2026-08-01")
    assert_equal "d >=2026-08-01", translated("since:8/1/2026")
    assert_equal "d >=2026-05", translated("after:2026-05")
    assert_equal "d >=2027-01-01", translated("after:2027-01-01")
    assert_equal "d <2026-08-01", translated("before:2026-08-01")
    assert_equal "d <2026-08-11", translated("before:today")
    assert_equal "d <2026-08", translated("before:2026-08")
    assert_equal "d <=2026-08", translated("until:2026-08")
    assert_equal "d <=2026-08-10", translated("until:yesterday")
    assert_equal "d 2d", translated("newer_than:2d")
    assert_equal "d !2w", translated("older_than:2w")
  end

  def test_leaves_untranslatable_values_and_keys_alone
    ["after:8am", "is:unread", "has:attachment", "in:inbox",
     "date:next-week", "date:31/12/2026",
     "re:launch", "b http://example.com", "d 1d", "f substack d 7d"].each do |q|
      assert_equal q, translated(q), "expected #{q.inspect} unchanged"
    end
  end

  def test_leaves_quoted_literals_alone
    assert_equal 's "date:today"', translated('s "date:today"')
  end

  def test_translates_in_place_preserving_the_rest_of_the_query
    assert_equal "f bob d 1d is:unread", translated("from:bob date:today is:unread")
  end

  def test_translate_returns_one_note_per_rewrite
    _, notes = S.translate("from:bob date:today is:unread", today: TODAY)
    assert_equal [["from:bob", "f bob"], ["date:today", "d 1d"]], notes
  end

  def test_translation_notice_lists_rewrites_and_is_nil_when_none
    _, notes = S.translate("date:today", today: TODAY)
    notice = S.translation_notice(notes)
    assert_includes notice, "date:today"
    assert_includes notice, "d 1d"
    assert_includes notice, "mmsearch --help"
    assert_nil S.translation_notice([])
  end

  def test_help_carries_the_translation_table
    help = Mailmate::CLI::Search.send(:build_parser, {}).to_s
    assert_includes help, "FOREIGN SYNTAX"
    assert_includes help, "date:today"
  end

  def test_mcp_description_discloses_translation_without_teaching_foreign_syntax
    mcp = Mailmate::MCP::TOOLS.find { |t| t[:name] == "search" }[:description]
    assert_includes mcp, "auto-translated"
    # The MCP teaches quicksearch, not the foreign table.
    refute_includes mcp, "FOREIGN SYNTAX"
  end
end
