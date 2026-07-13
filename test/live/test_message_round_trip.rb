# frozen_string_literal: true

require_relative "test_helper_live"

# Round-trip one message: pick the highest-numbered eml-id in the user's
# Inbox, then assert EmlLookup → HeaderReader → MidUrl all return non-nil.
# Confirms the on-disk format and the path/header/URL chain still works end
# to end against a live install.
class TestLiveMessageRoundTrip < Minitest::Test
  include Mailmate::TestHelpers
  include Mailmate::LiveTestHelpers

  def setup
    require_live_mailmate
  end

  def highest_eml_id_in_inbox
    graph = Mailmate::MailboxGraph.load
    dirs = Mailmate::SourceResolver.new(graph).resolve("INBOX")[:dirs]
    skip "no INBOX directories resolved" if dirs.empty?

    candidates = []
    dirs.each do |dir|
      Dir.glob(File.join(dir, "*.eml")) { |p| candidates << File.basename(p, ".eml").to_i }
    end
    skip "no eml files in INBOX" if candidates.empty?
    candidates.max
  end

  def test_eml_lookup_finds_path
    eml_id = highest_eml_id_in_inbox
    path = Mailmate::EmlLookup.path_for(eml_id)
    refute_nil path, "EmlLookup.path_for(#{eml_id}) returned nil"
    assert File.exist?(path), "path returned by EmlLookup does not exist: #{path}"
  end

  def test_header_reader_extracts_message_id
    eml_id = highest_eml_id_in_inbox
    path = Mailmate::EmlLookup.path_for(eml_id)
    skip "no path for eml #{eml_id}" unless path

    message_id = Mailmate::HeaderReader.message_id(path)
    refute_nil message_id, "no Message-ID extracted from #{path}"
  end

  def test_mid_url_constructible
    eml_id = highest_eml_id_in_inbox
    path = Mailmate::EmlLookup.path_for(eml_id)
    skip "no path for eml #{eml_id}" unless path
    message_id = Mailmate::HeaderReader.message_id(path)
    skip "no Message-ID for eml #{eml_id}" unless message_id

    url = Mailmate::MidUrl.for(message_id)
    refute_nil url
    assert_match(%r{\Amid:%3C.+%3E\z}, url)
  end
end
