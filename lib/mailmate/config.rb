# frozen_string_literal: true

require "yaml"
require "pathname"

module Mailmate
  # @api private
  #
  # The Config class is the storage and loader; consumers should reach it
  # through `Mailmate.config` rather than constructing instances directly.
  #
  # Mailmate.config — process-wide configuration with three-layer loading:
  #
  #   1. Built-in defaults (macOS-standard paths, no identities)
  #   2. YAML at ~/.config/mailmate/config.yml (silently ignored if missing)
  #   3. Environment variables (override YAML)
  #
  # Personal data — identity addresses, custom paths — lives in the YAML or
  # env vars, never in the gem source. `mmdiscover` populates the YAML on
  # first run from MailMate's own Sources.plist + Identities.plist.
  class Config
    DEFAULT_APP_SUPPORT_DIR = File.expand_path("~/Library/Application Support/MailMate")
    DEFAULT_CONFIG_PATH     = File.expand_path("~/.config/mailmate/config.yml")

    attr_reader :app_support_dir, :identities, :display_timezone

    def self.instance
      @instance ||= new
    end

    # Replace the singleton with a freshly-loaded config. Accepts the same
    # kwargs as `.new`, so tests can scope a config block without poking
    # ivars. Passing no args reloads from defaults (YAML at the default path,
    # real ENV).
    def self.reload!(yaml_path: DEFAULT_CONFIG_PATH, env: ENV)
      @instance = new(yaml_path: yaml_path, env: env)
    end

    def initialize(yaml_path: DEFAULT_CONFIG_PATH, env: ENV)
      @app_support_dir  = DEFAULT_APP_SUPPORT_DIR
      @identities       = []
      @display_timezone = nil

      load_yaml!(yaml_path)
      apply_env!(env)
    end

    # Derived paths. Each follows from app_support_dir; if a user has a
    # non-default MailMate install, overriding app_support_dir flows through.
    def imap_root
      File.join(app_support_dir, "Messages.noindex", "IMAP")
    end

    def db_headers
      File.join(app_support_dir, "Database.noindex", "Headers")
    end

    def mailboxes_plist
      File.join(app_support_dir, "Mailboxes.plist")
    end

    def sources_plist
      File.join(app_support_dir, "Sources.plist")
    end

    def identities_plist
      File.join(app_support_dir, "Identities.plist")
    end

    KNOWN_KEYS = %w[app_support_dir identities display_timezone].freeze

    private

    def load_yaml!(path)
      return unless File.exist?(path)
      data = YAML.safe_load_file(path) || {}
      unless data.is_a?(Hash)
        warn "Mailmate.config: #{path} did not parse as a YAML mapping; ignoring."
        return
      end

      unknown = data.keys - KNOWN_KEYS
      unless unknown.empty?
        warn "Mailmate.config: unknown key(s) in #{path}: #{unknown.join(", ")} (valid: #{KNOWN_KEYS.join(", ")})"
      end

      if data.key?("app_support_dir")
        val = data["app_support_dir"]
        if val.is_a?(String) && !val.empty?
          @app_support_dir = File.expand_path(val)
        else
          warn "Mailmate.config: app_support_dir in #{path} must be a non-empty string; ignoring (#{val.inspect})"
        end
      end

      if data.key?("identities")
        val = data["identities"]
        if val.is_a?(Array)
          @identities = val.map(&:to_s)
        else
          warn "Mailmate.config: identities in #{path} must be a list; ignoring (#{val.inspect})"
        end
      end

      if data.key?("display_timezone")
        val = data["display_timezone"]
        if val.nil? || (val.is_a?(String) && val.empty?)
          @display_timezone = nil
        elsif val.is_a?(String)
          @display_timezone = val
        else
          warn "Mailmate.config: display_timezone in #{path} must be a string (e.g. '-07:00'); ignoring (#{val.inspect})"
        end
      end
    end

    def apply_env!(env)
      if (v = env["MAILMATE_APP_SUPPORT_DIR"]) && !v.empty?
        @app_support_dir = File.expand_path(v)
      end
      if (v = env["MAILMATE_IDENTITIES"]) && !v.empty?
        @identities = v.split(",").map(&:strip).reject(&:empty?)
      end
      if (v = env["MAILMATE_DISPLAY_TIMEZONE"]) && !v.empty?
        @display_timezone = v
      end
    end
  end

  # Convenience: `Mailmate.config.imap_root` etc. Triggers first-run
  # discovery if `~/.config/mailmate/config.yml` doesn't exist yet
  # (interactive on a TTY, warn-and-continue otherwise).
  def self.config
    ensure_configured! if respond_to?(:ensure_configured!)
    Config.instance
  end
end
