# frozen_string_literal: true

require "optparse"
require "json"

module Mailmate
  module CLI
    # `mmtags` — list user tags MailMate knows about.
    #
    # Default: tags actually present on messages, counted from the `#flags`
    # index (system flags like `\Seen`, `$Forwarded` are excluded — only
    # user tags). Sorted by count desc.
    #
    # `--defined`: tags MailMate has registered in Preferences → Tags
    # (read from Tags.plist). May include tags that aren't on any message yet.
    # @api private
    module Tags
      extend self

      TAGS_PLIST_FILENAME = "Tags.plist"

      def run(argv)
        opts = parse_options(argv)
        if opts[:defined]
          emit_defined
        else
          emit_used
        end
        0
      end

      def parse_options(argv)
        opts = { defined: false }
        OptionParser.new do |o|
          o.banner = "Usage: mmtags [--defined]"
          o.separator ""
          o.separator "Default: tags actually applied to messages, with usage counts"
          o.separator "(read from MailMate's #flags index; system flags excluded)."
          o.separator ""
          o.on("--defined", "List tags defined in MailMate Preferences → Tags") { opts[:defined] = true }
        end.parse!(argv)
        opts
      end

      # ---- tags in use (#flags index) ----------------------------------------

      def emit_used
        counts = used_tag_counts
        width  = counts.keys.map(&:length).max || 3
        width  = [width, "tag".length].max
        $stdout.puts "#{"tag".ljust(width)}  count"
        counts.sort_by { |tag, n| [-n, tag] }.each do |tag, n|
          $stdout.puts "#{tag.ljust(width)}  #{n}"
        end
      end

      def used_tag_counts
        counts = Hash.new(0)
        Mailmate::IndexReader.for("#flags").each_record do |_eml_id, raw|
          next if raw.nil? || raw.empty?
          raw.split.each do |token|
            next if token.start_with?("\\", "$") # IMAP/Thunderbird system flags
            counts[token] += 1
          end
        end
        counts
      rescue ArgumentError
        # #flags index not available — fail gracefully (returns no tags).
        {}
      end

      # ---- tags defined in Preferences (Tags.plist) --------------------------

      def emit_defined
        defined_tag_names.each { |name| $stdout.puts name }
      end

      def defined_tag_names
        path = File.join(Mailmate.config.app_support_dir, TAGS_PLIST_FILENAME)
        return [] unless File.exist?(path)
        # plutil -convert json is more robust than reading binary plist directly.
        data = JSON.parse(`plutil -convert json -o - #{shellesc(path)}`)
        Array(data["tags"]).map { |t| t["displayName"] }.compact
      rescue StandardError
        []
      end

      def shellesc(s)
        "'#{s.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
