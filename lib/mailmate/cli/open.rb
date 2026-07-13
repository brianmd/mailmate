# frozen_string_literal: true

require "optparse"

module Mailmate
  module CLI
    # `mmopen` — open one MailMate message in the MailMate UI by handing the
    # `mid:` URL to macOS's `open`. Read-side (doesn't change message state),
    # but activates MailMate's window and brings it forward.
    #
    # Accepts any of the six id forms `EmlLookup.resolve_id` understands —
    # eml-id, RFC Message-ID with or without angle brackets, message://… URL,
    # or mid:… URL.
    # @api private
    module Open
      extend self

      def run(argv)
        opts = parse_options(argv)
        input = argv.first
        return usage_error("missing <id>") if input.nil? || input.empty?

        eml_id = Mailmate::EmlLookup.resolve_id(input)
        if eml_id.nil? || eml_id.zero?
          warn "mmopen: not found: #{input.inspect} (couldn't resolve as eml-id or Message-ID)"
          return 1
        end

        path = Mailmate::EmlLookup.path_for(eml_id)
        unless path
          warn "mmopen: not found: #{eml_id}.eml"
          return 1
        end

        message_id = Mailmate::HeaderReader.message_id(path)
        unless message_id
          warn "mmopen: could not find Message-ID in #{path}"
          return 1
        end

        url = Mailmate::MidUrl.for(message_id)
        if opts[:print_only]
          $stdout.puts url
          return 0
        end

        cmd = ["/usr/bin/open"]
        cmd << "-g" if opts[:background]
        cmd << url
        system(*cmd)
        $?.exitstatus
      end

      def parse_options(argv)
        opts = { print_only: false, background: false }
        OptionParser.new do |o|
          o.banner = "Usage: mmopen <id> [--print] [--background|-g]"
          o.separator ""
          o.separator "Open a MailMate message in MailMate's UI. <id> can be a local"
          o.separator "eml-id, an RFC Message-ID (with or without angle brackets), or"
          o.separator "a message://… or mid:… URL."
          o.on("--print", "Print the mid: URL instead of opening it (for piping)") { opts[:print_only] = true }
          o.on("-g", "--background", "Open without bringing MailMate to the foreground") { opts[:background] = true }
        end.parse!(argv)
        opts
      end

      def usage_error(msg)
        warn "mmopen: #{msg}"
        warn "Usage: mmopen <id> [--print] [--background|-g]"
        2
      end
    end
  end
end
