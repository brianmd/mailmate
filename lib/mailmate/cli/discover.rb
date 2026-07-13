# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"

module Mailmate
  module CLI
    # `mmdiscover` — bootstrap ~/.config/mailmate/{config.yml,bundle_loader.rb}
    # from MailMate's own Sources.plist and Identities.plist.
    #
    # First-run UX: a user installs the gem, runs `mmdiscover`, sees their
    # accounts and identity addresses laid out, confirms, and the gem now
    # knows who they are without any hand-editing of YAML or `plutil`
    # archaeology.
    # @api private
    module Discover
      extend self

      CONFIG_DIR    = File.expand_path("~/.config/mailmate")
      CONFIG_FILE   = File.join(CONFIG_DIR, "config.yml")
      LOADER_FILE   = File.join(CONFIG_DIR, "bundle_loader.rb")

      def run(argv)
        opts = parse_options(argv)
        app_support_dir = opts[:app_support_dir] || File.expand_path("~/Library/Application Support/MailMate")

        unless File.directory?(app_support_dir)
          warn "mmdiscover: MailMate app-support directory not found at #{app_support_dir}"
          warn "  Pass --app-support-dir if your install is elsewhere, or check that MailMate is installed."
          return 1
        end

        sources_plist    = File.join(app_support_dir, "Sources.plist")
        identities_plist = File.join(app_support_dir, "Identities.plist")

        accounts   = read_accounts(sources_plist)
        identities = read_identities(identities_plist)

        $stdout.puts "Found #{accounts.size} account#{"s" if accounts.size != 1} in Sources.plist:"
        accounts.each { |a| $stdout.puts "  #{a[:name].ljust(35)}(#{a[:host]})" }
        $stdout.puts
        $stdout.puts "Found #{identities.size} identity address#{"es" if identities.size != 1} in Identities.plist:"
        identities.each { |addr| $stdout.puts "  #{addr}" }
        $stdout.puts

        # Compare against existing config, if any, and surface differences.
        # Without --force we won't silently overwrite manual additions
        # (e.g. aliases that aren't outgoing identities in MailMate).
        existing_identities = read_existing_identities(CONFIG_FILE)
        if existing_identities && !opts[:force] && !opts[:dry_run]
          only_in_existing = existing_identities - identities
          only_in_new      = identities - existing_identities

          if !only_in_existing.empty? || !only_in_new.empty?
            $stdout.puts "Existing #{CONFIG_FILE} has a different identity set:"
            only_in_existing.each { |a| $stdout.puts "  - #{a}  (in current config, NOT in Identities.plist)" }
            only_in_new.each      { |a| $stdout.puts "  + #{a}  (in Identities.plist, NOT in current config)" }
            $stdout.puts
            $stdout.puts "Re-run with --force to overwrite, or hand-merge if you have manual additions to preserve."
            return 0
          end
        end

        if opts[:dry_run]
          $stdout.puts "(--dry-run) Would write #{CONFIG_FILE} and #{LOADER_FILE}; skipping."
          return 0
        end

        unless opts[:yes]
          $stdout.print "Write these to #{CONFIG_FILE}? [y/N] "
          response = $stdin.gets&.strip&.downcase
          unless %w[y yes].include?(response)
            $stdout.puts "Aborted."
            return 0
          end
        end

        FileUtils.mkdir_p(CONFIG_DIR)
        write_config(identities, app_support_dir, opts[:app_support_dir])
        write_bundle_loader

        $stdout.puts "Wrote #{CONFIG_FILE}"
        $stdout.puts "Wrote #{LOADER_FILE}"
        0
      end

      def parse_options(argv)
        opts = { dry_run: false, yes: false, force: false, app_support_dir: nil }
        OptionParser.new do |o|
          o.banner = "Usage: mmdiscover [--app-support-dir PATH] [--dry-run] [--yes] [--force]"
          o.on("--app-support-dir PATH", "Override the MailMate app-support location") { |p| opts[:app_support_dir] = File.expand_path(p) }
          o.on("--dry-run", "Print what would be written; don't write") { opts[:dry_run] = true }
          o.on("-y", "--yes", "Skip the y/N prompt") { opts[:yes] = true }
          o.on("--force", "Overwrite existing config even if it has identities not in Identities.plist") { opts[:force] = true }
        end.parse!(argv)
        opts
      end

      # Read the existing config.yml's `identities:` list, if the file exists.
      # Returns Array<String> (possibly empty) or nil if the file is missing.
      def read_existing_identities(path)
        return nil unless File.exist?(path)
        require "yaml"
        data = YAML.safe_load_file(path) rescue nil
        return [] unless data.is_a?(Hash)
        Array(data["identities"]).map { |a| a.to_s.downcase.strip }.reject(&:empty?)
      end

      # Read Sources.plist via plutil. Returns Array<{name:, host:}>.
      def read_accounts(path)
        return [] unless File.exist?(path)
        json = `plutil -convert json -o - #{shellesc(path)}`
        data = JSON.parse(json) rescue {}
        sources = data["sources"] || data["Sources"] || []
        sources.map do |s|
          name = s["name"] || s["Name"] || "(unnamed)"
          server_url = s["serverURL"] || s["ServerURL"] || ""
          host = server_url.split("@").last || "(no host)"
          { name: name, host: host }
        end
      end

      # Read Identities.plist via plutil. Returns Array<String> of email
      # addresses, lowercased and deduplicated. Each identity entry has an
      # `emailAddresses` field that may be a single string or a newline-
      # delimited list.
      def read_identities(path)
        return [] unless File.exist?(path)
        json = `plutil -convert json -o - #{shellesc(path)}`
        data = JSON.parse(json) rescue {}
        ids = data["identities"] || data["Identities"] || []

        all = ids.flat_map do |i|
          raw = i["emailAddresses"] || i["EmailAddresses"] || i["emailAddress"] || ""
          raw.to_s.split(/[\s,]+/)
        end
        all.map { |a| a.strip.downcase }.reject(&:empty?).uniq
      end

      def write_config(identities, _app_support_dir, app_support_override)
        File.open(CONFIG_FILE, "w") do |f|
          f.puts "# Mailmate gem configuration — written by mmdiscover on #{Time.now.strftime("%Y-%m-%d %H:%M")}"
          f.puts
          if app_support_override
            f.puts "app_support_dir: #{app_support_override}"
            f.puts
          end
          f.puts "identities:"
          identities.each { |addr| f.puts "  - #{addr}" }
        end
      end

      def write_bundle_loader
        gem_lib = File.expand_path("../..", __dir__) # → ~/code/claude/mailmate/lib
        File.open(LOADER_FILE, "w") do |f|
          f.puts "# Mailmate gem bundle-loader — written by mmdiscover."
          f.puts "# MailMate bundle handlers `load` this file then `require \"mailmate\"`."
          f.puts "# Re-run mmdiscover to refresh if the gem's location changes."
          f.puts
          f.puts "$LOAD_PATH.unshift #{gem_lib.inspect} unless $LOAD_PATH.include?(#{gem_lib.inspect})"
        end
      end

      def shellesc(s)
        "'#{s.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
