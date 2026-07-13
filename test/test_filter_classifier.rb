# frozen_string_literal: true

require_relative "test_helper"

# Pure-logic tests for FilterClassifier — tier(), tier_for_paths(),
# combine_tiers(), and header_literals(). No fixtures needed; everything
# is driven through Mailmate.compile_filter.
class TestFilterClassifier < Minitest::Test
  include Mailmate::TestHelpers

  FC = Mailmate::FilterClassifier

  def ast(filter)
    Mailmate.compile_filter(filter)
  end

  # ---- tier ----

  def test_tier_index_only
    # #flags and #date are both index-backed.
    assert_equal :index, FC.tier(ast("#flags = '\\Seen'"))
    assert_equal :index, FC.tier(ast("#date > '2020-01-01 00:00:00 +0000'"))
  end

  def test_tier_index_with_and_chain
    a = ast("#flags = '\\Seen' and #date > '2020-01-01 00:00:00 +0000'")
    assert_equal :index, FC.tier(a)
  end

  def test_tier_header_when_one_header_path
    assert_equal :header, FC.tier(ast("from.name = 'Medium'"))
    assert_equal :header, FC.tier(ast("subject ~ 'digest'"))
  end

  def test_tier_header_when_mixed_index_and_header
    a = ast("#flags = '\\Seen' and from.name = 'Medium'")
    assert_equal :header, FC.tier(a)
  end

  def test_tier_full_when_any_body_head
    assert_equal :full, FC.tier(ast("#commonplus ~ 'unsubscribe'"))
    assert_equal :full, FC.tier(ast("#quoted ~ 'invoice'"))
  end

  def test_tier_full_dominates_in_and_chain
    a = ast("from.name = 'X' and #commonplus ~ 'y'")
    assert_equal :full, FC.tier(a)
  end

  def test_tier_walks_or_branches
    # OR with one body head → full.
    a = ast("subject ~ 'a' or #unquoted ~ 'b'")
    assert_equal :full, FC.tier(a)
  end

  def test_tier_walks_not
    a = ast("not (#commonplus ~ 'spam')")
    assert_equal :full, FC.tier(a)
  end

  # ---- tier_for_paths ----

  def test_tier_for_paths_index
    assert_equal :index, FC.tier_for_paths([["#flags"], ["#date"]])
  end

  def test_tier_for_paths_header
    assert_equal :header, FC.tier_for_paths([["#flags"], ["from", "name"]])
    assert_equal :header, FC.tier_for_paths([["subject"]])
  end

  def test_tier_for_paths_full
    assert_equal :full, FC.tier_for_paths([["#commonplus"]])
    assert_equal :full, FC.tier_for_paths([["subject"], ["#quoted"]])
  end

  def test_tier_for_paths_empty
    # No paths → no body, no index, defaults to header.
    assert_equal :header, FC.tier_for_paths([])
  end

  # ---- combine_tiers ----

  def test_combine_tiers_full_wins
    assert_equal :full, FC.combine_tiers(:index, :header, :full)
    assert_equal :full, FC.combine_tiers(:full, :index)
  end

  def test_combine_tiers_header_beats_index
    assert_equal :header, FC.combine_tiers(:index, :header)
    assert_equal :header, FC.combine_tiers(:header, :index, :index)
  end

  def test_combine_tiers_index_when_all_index
    assert_equal :index, FC.combine_tiers(:index, :index)
    assert_equal :index, FC.combine_tiers(:index)
  end

  # ---- header_literals ----

  def test_header_literals_simple_eq
    lits = FC.header_literals(ast("from.name = 'Medium'"))
    assert_equal ["medium"], lits
  end

  def test_header_literals_lowercases
    lits = FC.header_literals(ast("subject ~ 'URGENT'"))
    assert_equal ["urgent"], lits
  end

  def test_header_literals_collects_and_chain
    a = ast("from.name = 'Medium' and subject ~ 'digest'")
    lits = FC.header_literals(a)
    assert_equal %w[digest medium], lits.sort
  end

  def test_header_literals_skips_negated
    assert_empty FC.header_literals(ast("subject != 'spam'"))
    assert_empty FC.header_literals(ast("subject !~ 'spam'"))
  end

  def test_header_literals_skips_or_branches
    # OR alternatives aren't required — only top-level AND-chain literals count.
    a = ast("from.name = 'Medium' or from.name = 'Substack'")
    assert_empty FC.header_literals(a)
  end

  def test_header_literals_skips_body_heads
    # #commonplus isn't in PREFILTER_HEADS.
    assert_empty FC.header_literals(ast("#commonplus ~ 'unsubscribe'"))
  end

  def test_header_literals_skips_short_strings
    # < 3 bytes is too noisy for a prefilter — implementation drops it.
    assert_empty FC.header_literals(ast("subject ~ 'ab'"))
  end

  def test_header_literals_skips_non_ascii
    # Non-ASCII can't reliably match raw header bytes (which may be MIME-encoded).
    assert_empty FC.header_literals(ast("subject ~ 'café'"))
  end

  def test_header_literals_uniques
    a = ast("from.name = 'Medium' and subject ~ 'Medium'")
    assert_equal ["medium"], FC.header_literals(a)
  end
end
