# frozen_string_literal: true

require_relative "test_helper_live"

# Smoke-test every smart mailbox in the user's Mailboxes.plist: compile its
# filter expression, resolve its source set. Catches MailMate format drift —
# if Freron ships a build that changes plist schema or filter language, this
# is the canary.
class TestLiveSmartMailboxes < Minitest::Test
  include Mailmate::TestHelpers
  include Mailmate::LiveTestHelpers

  def setup
    require_live_mailmate
    @graph = Mailmate::MailboxGraph.load
  end

  def test_every_smart_mailbox_filter_compiles
    failures = []
    @graph.by_uuid.each do |uuid, entry|
      next unless entry[:filter] # only smart mailboxes have filters
      begin
        Mailmate.compile_filter(entry[:filter])
      rescue Mailmate::Lexer::Error, Mailmate::Parser::Error => e
        failures << "#{entry[:name].inspect} (#{uuid}): #{e.class}: #{e.message}"
      end
    end
    assert_empty failures, "compile failures:\n#{failures.join("\n")}"
  end

  def test_every_smart_mailbox_resolves_to_source_set
    sr = Mailmate::SourceResolver.new(@graph)
    failures = []
    @graph.by_uuid.each do |uuid, entry|
      next unless entry[:filter] # only smart mailboxes need source resolution
      begin
        sr.resolve(uuid)
      rescue StandardError => e
        failures << "#{entry[:name].inspect} (#{uuid}): #{e.class}: #{e.message}"
      end
    end
    assert_empty failures, "resolve failures:\n#{failures.join("\n")}"
  end
end
