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
      "is:unread"             => "is",
      "newer_than:2d"         => "newer_than" }.each do |query, key|
      tokens = S.foreign_tokens(query)
      refute_empty tokens, "expected #{query.inspect} to be flagged"
      assert_equal key, tokens.first.last
    end
  end

  def test_leaves_valid_quicksearch_alone
    ["d 1d", "f substack d 7d", "s \"invoice due\" !draft", "d 2026-08-10",
     "T urgent", "m brycer d 60d", "f !smith", ""].each do |query|
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
    assert_nil S.zero_result_hint("f PNMNotification d 1d")
    assert_nil S.zero_result_hint("")
  end

  def test_hint_handles_a_key_with_no_known_equivalent
    hint = S.zero_result_hint("is:unread")
    assert_includes hint, "is:unread"
    assert_includes hint, "mmsearch --help"
  end
end
