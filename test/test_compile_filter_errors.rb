# frozen_string_literal: true

require_relative "test_helper"

# Public-contract tests for Mailmate.compile_filter — the entry point CLIs
# call into. CLI code rescues these specific error classes, so locking them
# in protects against silent error-class drift.
class TestCompileFilterErrors < Minitest::Test
  include Mailmate::TestHelpers

  def test_lexer_error_raised_on_bad_lex
    assert_raises(Mailmate::Lexer::Error) do
      Mailmate.compile_filter("subject = 'unterminated")
    end
  end

  def test_parser_error_raised_on_bad_parse
    assert_raises(Mailmate::Parser::Error) do
      Mailmate.compile_filter("subject 'Medium'")  # missing operator
    end
  end

  def test_lexer_error_is_stdandard_error
    # CLI's `rescue StandardError` will catch — so confirm the ancestry.
    assert Mailmate::Lexer::Error.ancestors.include?(StandardError)
  end

  def test_parser_error_is_standard_error
    assert Mailmate::Parser::Error.ancestors.include?(StandardError)
  end

  def test_compile_filter_returns_ast_node_on_success
    ast = Mailmate.compile_filter("subject = 'x'")
    assert_kind_of Mailmate::AST::CompareNode, ast
  end

  def test_compile_filter_handles_whitespace_only
    # Empty/whitespace input — parser raises an error on the EOF token where
    # an expression is expected.
    assert_raises(Mailmate::Parser::Error) do
      Mailmate.compile_filter("   ")
    end
  end
end
