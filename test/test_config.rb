# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestConfig < Minitest::Test
  include Mailmate::TestHelpers

  def test_defaults_when_no_yaml_or_env
    cfg = Mailmate::Config.new(yaml_path: "/nonexistent", env: {})
    assert_equal File.expand_path("~/Library/Application Support/MailMate"), cfg.app_support_dir
    assert_equal [], cfg.identities
  end

  def test_derived_paths
    cfg = Mailmate::Config.new(yaml_path: "/nonexistent", env: { "MAILMATE_APP_SUPPORT_DIR" => "/tmp/mm" })
    assert_equal "/tmp/mm/Messages.noindex/IMAP", cfg.imap_root
    assert_equal "/tmp/mm/Database.noindex/Headers", cfg.db_headers
    assert_equal "/tmp/mm/Mailboxes.plist", cfg.mailboxes_plist
    assert_equal "/tmp/mm/Sources.plist", cfg.sources_plist
    assert_equal "/tmp/mm/Identities.plist", cfg.identities_plist
  end

  def test_yaml_loading
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        app_support_dir: /tmp/mailmate-from-yaml
        identities:
          - a@example.com
          - b@example.com
      YAML

      cfg = Mailmate::Config.new(yaml_path: path, env: {})
      assert_equal "/tmp/mailmate-from-yaml", cfg.app_support_dir
      assert_equal ["a@example.com", "b@example.com"], cfg.identities
    end
  end

  def test_yaml_expands_tilde_in_paths
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "app_support_dir: ~/Library/Application Support/Custom\n")

      cfg = Mailmate::Config.new(yaml_path: path, env: {})
      assert_equal File.expand_path("~/Library/Application Support/Custom"), cfg.app_support_dir
      # No literal `~` should remain.
      refute_includes cfg.app_support_dir, "~"
    end
  end

  def test_missing_yaml_is_not_an_error
    cfg = Mailmate::Config.new(yaml_path: "/nonexistent/path.yml", env: {})
    # Defaults still in place.
    assert_equal File.expand_path("~/Library/Application Support/MailMate"), cfg.app_support_dir
    assert_equal [], cfg.identities
  end

  def test_env_overrides_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        app_support_dir: /from-yaml
        identities:
          - yaml@example.com
      YAML

      cfg = Mailmate::Config.new(
        yaml_path: path,
        env: {
          "MAILMATE_APP_SUPPORT_DIR" => "/from-env",
          "MAILMATE_IDENTITIES" => "env1@example.com, env2@example.com",
        },
      )
      assert_equal "/from-env", cfg.app_support_dir
      assert_equal ["env1@example.com", "env2@example.com"], cfg.identities
    end
  end

  # `mine?` lives on Mailmate::Identity now (data here, semantics there).
  # Coverage for the predicate behavior is in test/test_identity.rb.

  def test_reload_accepts_overrides
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "identities:\n  - reloaded@example.com\n")

      orig = Mailmate::Config.instance_variable_get(:@instance)
      Mailmate::Config.reload!(yaml_path: path, env: {})
      assert_equal ["reloaded@example.com"], Mailmate.config.identities
    ensure
      Mailmate::Config.instance_variable_set(:@instance, orig)
    end
  end

  def test_reload_with_no_args_reloads_from_defaults
    # Just verifies the call shape; the result depends on whatever YAML / ENV
    # is in play at the moment.
    orig = Mailmate::Config.instance_variable_get(:@instance)
    cfg = Mailmate::Config.reload!
    assert_kind_of Mailmate::Config, cfg
  ensure
    Mailmate::Config.instance_variable_set(:@instance, orig)
  end

  def test_unknown_yaml_keys_emit_warning
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        app_support_dir: /tmp/mm
        identitis:  # typo
          - me@example.com
        bogus_key: 42
      YAML
      _, err = capture_io { Mailmate::Config.new(yaml_path: path, env: {}) }
      assert_includes err, "unknown key"
      assert_includes err, "identitis"
      assert_includes err, "bogus_key"
    end
  end

  def test_identities_must_be_array
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "identities: me@example.com\n") # string, not array
      cfg = nil
      _, err = capture_io { cfg = Mailmate::Config.new(yaml_path: path, env: {}) }
      assert_includes err, "identities"
      assert_includes err, "must be a list"
      assert_equal [], cfg.identities, "Defaults to empty on type mismatch"
    end
  end

  def test_app_support_dir_must_be_string
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "app_support_dir: 42\n")
      cfg = nil
      _, err = capture_io { cfg = Mailmate::Config.new(yaml_path: path, env: {}) }
      assert_includes err, "app_support_dir"
      assert_equal File.expand_path("~/Library/Application Support/MailMate"), cfg.app_support_dir
    end
  end
end
