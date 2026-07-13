# frozen_string_literal: true

require "optparse"
require "uri"

module Mailmate
  module CLI
    # `mm-mailboxes` — enumerate accounts, their IMAP mailboxes, and the
    # smart mailboxes MailMate has defined. Read-side (no UI activation), but
    # uses the `mm-` prefix anyway so it doesn't shadow `mmmessage` in
    # tab-completion: `mmm<tab>` keeps resolving to `mmmessage`.
    # @api private
    module Mailboxes
      extend self

      def run(argv)
        opts = parse_options(argv)

        accounts = enumerate_imap_accounts(count: opts[:count])
        smart    = enumerate_smart_mailboxes

        if opts[:csv]
          emit_csv(accounts, smart, opts)
        else
          emit_grouped(accounts, smart, opts)
        end
        0
      end

      def parse_options(argv)
        opts = { count: true, csv: false, align: true }
        OptionParser.new do |o|
          o.banner = "Usage: mm-mailboxes [options]"
          o.separator ""
          o.separator "List MailMate accounts, their IMAP mailboxes, and smart mailboxes."
          o.separator "Default output groups by account with a section header per account."
          o.on("--no-count",  "Skip .eml counts (faster on large stores)") { opts[:count] = false }
          o.on("--csv",       "Flat CSV output (one row per mailbox, account repeated)") { opts[:csv] = true }
          o.on("--no-align",  "Plain CSV (no column padding) — implies --csv") { opts[:csv] = true; opts[:align] = false }
        end.parse!(argv)
        opts
      end

      # ---- enumeration --------------------------------------------------------

      # Returns [[account_display, [{mailbox: 'INBOX', count: 127}, …]], …]
      # Account names are pulled from on-disk dir names under imap_root, with
      # MailMate's URL-encoding decoded for display (`%40` → `@`).
      def enumerate_imap_accounts(count: true)
        root = Mailmate.config.imap_root
        return [] unless File.directory?(root)

        Dir.children(root).sort.filter_map do |dirname|
          account_dir = File.join(root, dirname)
          next unless File.directory?(account_dir)

          mailboxes = collect_mailboxes(account_dir, count: count)
          next if mailboxes.empty?

          [decode_account(dirname), mailboxes]
        end
      end

      def collect_mailboxes(account_dir, count:)
        prefix = "#{account_dir}/"
        Dir.glob("#{account_dir}/**/Messages").sort.filter_map do |messages_dir|
          next unless File.directory?(messages_dir)
          rel = messages_dir.sub(prefix, "").sub(%r{/Messages\z}, "")
          # Strip the .mailbox suffix from each segment for display.
          mailbox_name = rel.split("/").map { |s| s.sub(/\.mailbox\z/, "") }.join("/")
          row = { mailbox: mailbox_name }
          row[:count] = count ? Dir.children(messages_dir).count { |f| f.end_with?(".eml") } : nil
          row
        end
      end

      # Returns array of smart-mailbox names (sorted).
      def enumerate_smart_mailboxes
        graph = Mailmate::MailboxGraph.load
        graph.by_uuid.values
             .select { |m| m[:filter] }
             .map    { |m| m[:name] }
             .compact
             .uniq
             .sort
      rescue StandardError
        []
      end

      # MailMate's account dirs encode `@` as `%40` (they're literally IMAP
      # URL fragments). Decode for display so users see real addresses.
      def decode_account(dirname)
        URI.decode_www_form_component(dirname)
      end

      # ---- output -------------------------------------------------------------

      def emit_grouped(accounts, smart, opts)
        accounts.each do |account, mailboxes|
          $stdout.puts account
          mailboxes.each do |m|
            count_str = opts[:count] ? format_count(m[:count]) : ""
            $stdout.puts "  #{m[:mailbox].ljust(50)}imap   #{count_str}"
          end
        end
        unless smart.empty?
          $stdout.puts
          $stdout.puts "Smart Mailboxes"
          smart.each { |name| $stdout.puts "  #{name.ljust(50)}smart  -" }
        end
      end

      def emit_csv(accounts, smart, opts)
        rows = []
        accounts.each do |account, mailboxes|
          mailboxes.each do |m|
            rows << [account, m[:mailbox], "imap", opts[:count] ? format_count(m[:count]) : ""]
          end
        end
        smart.each { |name| rows << ["(smart)", name, "smart", "-"] }

        header = %w[account mailbox type count]
        if opts[:align]
          display = ([header] + rows)
          widths  = Array.new(header.size, 0)
          display.each { |r| r.each_with_index { |c, i| widths[i] = c.to_s.length if c.to_s.length > widths[i] } }
          display.each do |r|
            $stdout.puts r.each_with_index.map { |c, i| i == r.size - 1 ? c.to_s : c.to_s.ljust(widths[i]) }.join(",")
          end
        else
          require "csv"
          $stdout.puts CSV.generate_line(header)
          rows.each { |r| $stdout.puts CSV.generate_line(r) }
        end
      end

      def format_count(n)
        n.nil? ? "-" : n.to_s
      end
    end
  end
end
