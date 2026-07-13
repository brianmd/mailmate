# frozen_string_literal: true

require_relative "test_helper"

class TestParser < Minitest::Test
  include Mailmate::TestHelpers

  def parse(s)
    Mailmate.compile_filter(s)
  end

  # ---- basic clauses ----

  def test_simple_equality
    ast = parse("from.name = 'Medium'")
    assert_kind_of Mailmate::AST::CompareNode, ast
    assert_equal ["from", "name"], ast.path
    assert_equal "=", ast.op
    assert_kind_of Mailmate::AST::LiteralStringNode, ast.value
    assert_equal "Medium", ast.value.value
  end

  def test_modifier_flags_carried_through
    ast = parse("subject =[c] 'hello'")
    assert_kind_of Mailmate::AST::CompareNode, ast
    assert_includes ast.flags, "c"
  end

  def test_contains
    ast = parse("subject ~ 'urgent'")
    assert_kind_of Mailmate::AST::CompareNode, ast
    assert_equal "~", ast.op
  end

  def test_exists
    ast = parse("list-id.identifier exists")
    assert_kind_of Mailmate::AST::ExistsNode, ast
    assert_equal ["list-id", "identifier"], ast.path
  end

  # ---- boolean composition ----

  def test_explicit_and
    ast = parse("from.name = 'A' and subject = 'B'")
    assert_kind_of Mailmate::AST::AndNode, ast
    assert_equal 2, ast.children.size
  end

  def test_explicit_or
    ast = parse("from.name = 'A' or from.name = 'B'")
    assert_kind_of Mailmate::AST::OrNode, ast
    assert_equal 2, ast.children.size
  end

  def test_or_precedence_lower_than_and
    # A and B or C and D  →  (A and B) or (C and D)
    ast = parse("a = 'A' and b = 'B' or c = 'C' and d = 'D'")
    assert_kind_of Mailmate::AST::OrNode, ast
    assert_kind_of Mailmate::AST::AndNode, ast.children[0]
    assert_kind_of Mailmate::AST::AndNode, ast.children[1]
  end

  def test_parens_override_precedence
    ast = parse("(a = 'A' or b = 'B') and c = 'C'")
    assert_kind_of Mailmate::AST::AndNode, ast
    assert_kind_of Mailmate::AST::OrNode, ast.children[0]
  end

  def test_not
    ast = parse("not (from.name = 'X')")
    assert_kind_of Mailmate::AST::NotNode, ast
  end

  def test_implicit_and
    # Two clauses without an explicit connector are joined by AND.
    ast = parse("from.name = 'A' subject = 'B'")
    assert_kind_of Mailmate::AST::AndNode, ast
  end

  # ---- shorthand paths ----

  def test_hash_shorthand
    ast = parse("#any-address ~ 'freron'")
    assert_kind_of Mailmate::AST::CompareNode, ast
    assert_equal ["#any-address"], ast.path
  end

  def test_nested_path
    ast = parse("from.address.domain.top-level = 'com'")
    assert_kind_of Mailmate::AST::CompareNode, ast
    assert_equal ["from", "address", "domain", "top-level"], ast.path
  end

  # ---- relative dates ----

  def test_relative_date
    ast = parse("#date-received > 1 days ago")
    assert_kind_of Mailmate::AST::CompareNode, ast
    assert_kind_of Mailmate::AST::RelativeDateNode, ast.value
    assert_equal 1, ast.value.n
    assert_equal :day, ast.value.unit
  end

  def test_relative_date_weeks
    ast = parse("#date-received > 2 weeks ago")
    assert_equal :week, ast.value.unit
    assert_equal 2, ast.value.n
  end

  def test_relative_date_with_f_flag
    ast = parse("#date-received >[f] 1 months ago")
    assert_includes ast.flags, "f"
    assert_equal :month, ast.value.unit
  end

  # ---- absolute dates ----

  def test_absolute_date
    ast = parse("#date-received < '2025-01-01 00:00:00 +0000'")
    assert_kind_of Mailmate::AST::AbsoluteDateNode, ast.value
    assert_kind_of Time, ast.value.time
  end

  # ---- variable references ----

  def test_var_reference
    ast = parse("#recipient.address = $SENT.from.address")
    assert_kind_of Mailmate::AST::CompareNode, ast
    assert_kind_of Mailmate::AST::VarRefNode, ast.value
    assert_equal "SENT", ast.value.var
    assert_equal ["from", "address"], ast.value.path
  end

  # ---- errors ----

  def test_missing_operator_raises
    assert_raises(Mailmate::Parser::Error) do
      parse("from.name 'Medium'")
    end
  end

  def test_dangling_dot_raises
    assert_raises(Mailmate::Parser::Error) do
      parse("from. = 'A'")
    end
  end

  # ---- edge cases ----

  def test_deeply_nested_precedence
    # A and B and (C or D) or E
    # → Or( And(A, B, Or(C, D)), E )
    ast = parse("a = 'A' and b = 'B' and (c = 'C' or d = 'D') or e = 'E'")
    assert_kind_of Mailmate::AST::OrNode, ast
    assert_equal 2, ast.children.size
    assert_kind_of Mailmate::AST::AndNode, ast.children[0]
    # The And node should have flattened siblings — A, B, and the parenthesized Or
    and_node = ast.children[0]
    assert_equal 3, and_node.children.size
    assert_kind_of Mailmate::AST::OrNode, and_node.children[2]
  end

  def test_implicit_and_with_three_clauses
    ast = parse("a = '1' b = '2' c = '3'")
    assert_kind_of Mailmate::AST::AndNode, ast
    assert_equal 3, ast.children.size
  end

  def test_compound_op_flags_parsed
    # Lexer accepts =[ca] / =[cf] etc.; parser must carry both flags.
    ast = parse("subject =[ca] 'hi'")
    assert_includes ast.flags, "c"
    assert_includes ast.flags, "a"
  end

  def test_neq_with_flags
    ast = parse("subject !=[c] 'Re:'")
    assert_equal "!=", ast.op
    assert_includes ast.flags, "c"
  end

  def test_date_string_branches_to_absolute_date
    ast = parse("#date < '2026-01-15 12:00:00 +0000'")
    assert_kind_of Mailmate::AST::AbsoluteDateNode, ast.value
    assert_equal 2026, ast.value.time.year
  end

  def test_plain_string_not_treated_as_date
    ast = parse("subject = '2026-bug-tracker'")
    assert_kind_of Mailmate::AST::LiteralStringNode, ast.value
    assert_equal "2026-bug-tracker", ast.value.value
  end

  def test_number_alone_is_number_not_date
    # parse_value's number branch returns a NumberNode if there's no UNIT 'ago' follow-up.
    # MailMate filter language rarely uses bare numbers, but the grammar permits it.
    ast = parse("subject = 42")
    assert_kind_of Mailmate::AST::NumberNode, ast.value
    assert_equal 42, ast.value.value
  end

  def test_var_ref_with_empty_path
    # $VAR with no .path — parser must accept this (path is empty array).
    ast = parse("subject = $SENT")
    assert_kind_of Mailmate::AST::VarRefNode, ast.value
    assert_equal "SENT", ast.value.var
    assert_equal [], ast.value.path
  end
end
