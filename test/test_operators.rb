# frozen_string_literal: true

require_relative "test_helper"

class TestOperators < Minitest::Test
  include Mailmate::TestHelpers

  # ---- equality / inequality ----

  def test_eq_string
    assert Mailmate::Operators.compare("Medium", "=", [], "Medium")
    refute Mailmate::Operators.compare("Medium", "=", [], "medium")
  end

  def test_neq_string
    refute Mailmate::Operators.compare("Medium", "!=", [], "Medium")
    assert Mailmate::Operators.compare("Medium", "!=", [], "Other")
  end

  # ---- contains / not-contains ----

  def test_contains
    assert Mailmate::Operators.compare("freron.com", "~", [], "freron")
    refute Mailmate::Operators.compare("example.com", "~", [], "freron")
  end

  def test_not_contains
    refute Mailmate::Operators.compare("freron.com", "!~", [], "freron")
    assert Mailmate::Operators.compare("example.com", "!~", [], "freron")
  end

  # ---- modifier flag [c] (case-insensitive) ----

  def test_eq_case_insensitive_with_c_flag
    assert Mailmate::Operators.compare("MEDIUM", "=", ["c"], "medium")
    assert Mailmate::Operators.compare("medium", "=", ["c"], "MEDIUM")
    refute Mailmate::Operators.compare("Other", "=", ["c"], "medium")
  end

  def test_contains_case_insensitive_with_c_flag
    assert Mailmate::Operators.compare("HELLO Freron World", "~", ["c"], "freron")
  end

  # ---- modifier flag [a] (accent-insensitive) ----

  def test_eq_accent_insensitive_with_a_flag
    assert Mailmate::Operators.compare("café", "=", ["a"], "cafe")
    refute Mailmate::Operators.compare("café", "=", [], "cafe")
  end

  def test_combined_c_and_a_flags
    assert Mailmate::Operators.compare("CAFÉ", "=", %w[c a], "cafe")
  end

  # ---- ordered comparisons ----

  def test_lt_numeric
    assert Mailmate::Operators.compare(3, "<", [], 5)
    refute Mailmate::Operators.compare(5, "<", [], 3)
    refute Mailmate::Operators.compare(5, "<", [], 5)
  end

  def test_lte_numeric
    assert Mailmate::Operators.compare(5, "<=", [], 5)
    assert Mailmate::Operators.compare(3, "<=", [], 5)
  end

  def test_gt_numeric
    assert Mailmate::Operators.compare(7, ">", [], 5)
    refute Mailmate::Operators.compare(3, ">", [], 5)
  end

  def test_gte_numeric
    assert Mailmate::Operators.compare(5, ">=", [], 5)
    assert Mailmate::Operators.compare(7, ">=", [], 5)
  end

  def test_date_compare_via_time_parse
    older = Time.parse("2025-01-01 00:00:00 +0000")
    newer = Time.parse("2025-12-31 00:00:00 +0000")
    assert Mailmate::Operators.compare(older, "<", [], newer)
    refute Mailmate::Operators.compare(older, ">", [], newer)
  end

  def test_string_compare_attempts_time_parse
    assert Mailmate::Operators.compare("2025-01-01", "<", [], "2025-12-31")
  end

  def test_compare_ordered_returns_false_for_uncoerceable
    refute Mailmate::Operators.compare("not-a-date", "<", [], "also-not-a-date")
  end

  # ---- unknown operator ----

  def test_unknown_operator_raises
    assert_raises(ArgumentError) do
      Mailmate::Operators.compare("a", "??", [], "b")
    end
  end

  # ---- normalize ----

  def test_normalize_passes_time_through
    t = Time.now
    assert_equal t, Mailmate::Operators.normalize(t, [])
  end

  def test_normalize_passes_numbers_through
    assert_equal 42, Mailmate::Operators.normalize(42, ["c"])
  end

  def test_normalize_lowercases_with_c_flag
    assert_equal "hello", Mailmate::Operators.normalize("HELLO", ["c"])
  end

  def test_normalize_strips_accents_with_a_flag
    assert_equal "cafe", Mailmate::Operators.normalize("café", ["a"])
  end

  # ---- relative_date ----

  def test_relative_date_days
    t = Mailmate::Operators.relative_date(1, :day)
    assert_in_delta Time.now - 86_400, t, 5
  end

  def test_relative_date_weeks
    t = Mailmate::Operators.relative_date(2, :week)
    assert_in_delta Time.now - (2 * 7 * 86_400), t, 5
  end

  def test_relative_date_with_f_flag_floors_to_day
    t = Mailmate::Operators.relative_date(1, :day, ["f"])
    assert_equal 0, t.hour
    assert_equal 0, t.min
    assert_equal 0, t.sec
  end

  def test_relative_date_with_f_flag_floors_to_start_of_month
    t = Mailmate::Operators.relative_date(1, :month, ["f"])
    assert_equal 1, t.day
    assert_equal 0, t.hour
  end

  def test_relative_date_with_f_flag_floors_to_start_of_year
    t = Mailmate::Operators.relative_date(1, :year, ["f"])
    assert_equal 1, t.month
    assert_equal 1, t.day
  end

  def test_relative_date_with_f_flag_floors_week_to_monday
    t = Mailmate::Operators.relative_date(0, :week, ["f"])
    assert_equal 1, t.to_date.cwday, "Monday is cwday 1"
  end
end
