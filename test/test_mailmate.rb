# frozen_string_literal: true

require_relative "test_helper"

class TestMailmate < Minitest::Test
  include Mailmate::TestHelpers

  def test_version_defined
    refute_nil Mailmate::VERSION
    assert_match(/\A\d+\.\d+\.\d+\z/, Mailmate::VERSION)
  end

  def test_top_level_classes_load
    # If any require_relative in lib/mailmate.rb is broken, this catches it.
    assert defined?(Mailmate::Config)
    assert defined?(Mailmate::PlatformError)
    assert defined?(Mailmate::IndexReader)
    assert defined?(Mailmate::Lexer)
    assert defined?(Mailmate::Parser)
    assert defined?(Mailmate::Evaluator)
    assert defined?(Mailmate::MailboxGraph)
    assert defined?(Mailmate::SourceResolver)
    assert defined?(Mailmate::VarResolver)
    assert defined?(Mailmate::FilterClassifier)
  end

  def test_compile_filter_returns_an_ast
    ast = Mailmate.compile_filter("from.name = 'Medium'")
    refute_nil ast
  end

  def test_platform_error_check_on_darwin
    skip "darwin-only" unless RUBY_PLATFORM.include?("darwin")
    # On darwin, the check should NOT raise.
    Mailmate::PlatformError.check_darwin!(component: "test")
  end
end
