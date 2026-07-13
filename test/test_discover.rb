# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/discover"
require "tmpdir"
require "stringio"

class TestDiscover < Minitest::Test
  include Mailmate::TestHelpers

  def test_read_existing_identities_returns_empty_for_missing_file
    assert_nil Mailmate::CLI::Discover.read_existing_identities("/nonexistent/config.yml")
  end

  def test_read_existing_identities_parses_yaml_list
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "identities:\n  - a@example.com\n  - B@Example.Com\n")
      assert_equal ["a@example.com", "b@example.com"], Mailmate::CLI::Discover.read_existing_identities(path)
    end
  end

  def test_read_existing_identities_returns_empty_for_yaml_without_identities
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "app_support_dir: /tmp\n")
      assert_equal [], Mailmate::CLI::Discover.read_existing_identities(path)
    end
  end

  # ---- read_accounts ----

  def test_read_accounts_parses_sources_plist
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Sources.plist")
      json = <<~JSON
        { "sources": [
            { "name": "Work",     "serverURL": "imaps://brian@imap.example.com:993" },
            { "name": "Personal", "serverURL": "imaps://b%40ex@mail.example.org:993" }
          ]
        }
      JSON
      File.write(path, json)
      accounts = Mailmate::CLI::Discover.read_accounts(path)
      assert_equal 2, accounts.size
      assert_equal "Work", accounts.first[:name]
      assert_equal "imap.example.com:993", accounts.first[:host]
    end
  end

  def test_read_accounts_missing_file_returns_empty
    assert_equal [], Mailmate::CLI::Discover.read_accounts("/nonexistent/Sources.plist")
  end

  # ---- read_identities ----

  def test_read_identities_parses_emailaddresses_field
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Identities.plist")
      # MailMate stores emailAddresses as a newline- or comma-separated string.
      json = <<~JSON
        { "identities": [
            { "emailAddresses": "alice@example.com\\nALICE@example.com" },
            { "emailAddresses": "bob@example.org" }
          ]
        }
      JSON
      File.write(path, json)
      ids = Mailmate::CLI::Discover.read_identities(path)
      # Deduplicates case-insensitively (downcased).
      assert_equal %w[alice@example.com bob@example.org].sort, ids.sort
    end
  end

  def test_read_identities_missing_file_returns_empty
    assert_equal [], Mailmate::CLI::Discover.read_identities("/nonexistent/Identities.plist")
  end
end
