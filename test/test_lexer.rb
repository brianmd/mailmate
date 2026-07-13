# frozen_string_literal: true

require_relative "test_helper"

# Smoke tests over the filter lexer. Exhaustive coverage will land alongside
# Phase C extractions; these just verify the lexer survives the gem move.
class TestLexer < Minitest::Test
  include Mailmate::TestHelpers

  def test_lex_simple_equality
    tokens = Mailmate::Lexer.lex("from.name = 'Medium'")
    refute_empty tokens
  end

  def test_lex_compound_expression
    # Pulled (verbatim) from MailMate's filter language; representative of the
    # actual smart-mailbox filters this gem evaluates.
    tokens = Mailmate::Lexer.lex("#flags.flag !=[x] '\\Seen' and #date-received >[f] 1 days ago")
    refute_empty tokens
  end

  def test_lex_with_paren_grouping
    tokens = Mailmate::Lexer.lex("(from.address = 'a@b.com' or from.address = 'c@d.com') and subject ~ 'hi'")
    refute_empty tokens
  end

  def test_lex_variable_reference
    tokens = Mailmate::Lexer.lex("#recipient.address = $SENT.from.address")
    refute_empty tokens
  end

  def test_compile_filter_end_to_end
    # Smoke test: lexer + parser produce an AST without raising on a known-good
    # MailMate filter string. Exhaustive AST-shape assertions are Phase C scope.
    ast = Mailmate.compile_filter("from.name = 'Medium'")
    refute_nil ast
  end

  # ---- error paths ----

  def test_unterminated_string_raises
    err = assert_raises(Mailmate::Lexer::Error) do
      Mailmate::Lexer.lex("from.name = 'Medium")
    end
    assert_match(/unterminated/i, err.message)
  end

  def test_unexpected_char_raises
    err = assert_raises(Mailmate::Lexer::Error) do
      Mailmate::Lexer.lex("from.name @ 'x'")
    end
    assert_match(/unexpected/i, err.message)
  end

  def test_empty_variable_name_raises
    err = assert_raises(Mailmate::Lexer::Error) do
      Mailmate::Lexer.lex("subject = $")
    end
    assert_match(/empty variable/i, err.message)
  end

  def test_missing_closing_bracket_on_op_flags_raises
    err = assert_raises(Mailmate::Lexer::Error) do
      Mailmate::Lexer.lex("subject =[c 'x'")
    end
    assert_match(/expected \]/i, err.message)
  end

  def test_empty_shorthand_raises
    err = assert_raises(Mailmate::Lexer::Error) do
      Mailmate::Lexer.lex("# = 'x'")
    end
    assert_match(/empty shorthand/i, err.message)
  end

  # ---- happy-path edge cases ----

  def test_combined_op_flags_carry_through
    tokens = Mailmate::Lexer.lex("subject =[ca] 'x'")
    op = tokens.find { |t| t[0] == :op }
    assert_equal "=", op[1]
    assert_equal %w[c a], op[2]
  end

  def test_double_hash_shorthand
    tokens = Mailmate::Lexer.lex("##tags ~ 'inbox'")
    assert_equal :shorthand, tokens.first[0]
    assert_equal "##tags", tokens.first[1]
  end

  def test_escapes_in_string
    tokens = Mailmate::Lexer.lex("subject = 'it\\'s a \\\\test'")
    str = tokens.find { |t| t[0] == :string }
    assert_equal "it's a \\test", str[1]
  end
end
