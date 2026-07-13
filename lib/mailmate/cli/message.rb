# frozen_string_literal: true

require "optparse"
# `mail` is required lazily inside run() — the --raw and --mailmate paths
# never parse the message, so they shouldn't pay ~50 ms loading the gem.

module Mailmate
  module CLI
    # `mmmessage` — print a decoded MailMate message by its eml-id.
    # Ports the standalone mailmate-message script. Headers + plain-text body
    # by default; `--raw` for the original .eml bytes; `--text-only` for just
    # the body.
    # @api private
    module Message
      extend self

      def run(argv)
        opts = parse_options(argv)
        input = argv.first

        return usage_error("missing <id>") if input.nil? || input.empty?

        # Accept either eml-id (all digits) or RFC Message-ID (with or without
        # angle brackets). Lets you copy/paste from any machine without caring
        # whether the local eml-id matches.
        eml_id = Mailmate::EmlLookup.resolve_id(input)
        if eml_id.nil? || eml_id.zero?
          warn "Not found: #{input.inspect} (couldn't resolve as eml-id or Message-ID)"
          return 1
        end

        path = Mailmate::EmlLookup.path_for(eml_id)
        unless path
          warn "Not found: #{eml_id}.eml"
          return 1
        end

        if opts[:mailmate]
          require_relative "open"
          # Hand off to mmopen — same id resolution already done, but Open re-resolves
          # so the two paths stay symmetric. Tiny double-resolve is fine.
          return Mailmate::CLI::Open.run([input])
        end

        if opts[:raw]
          $stdout.binmode
          $stdout.write(File.binread(path))
          return 0
        end

        require "mail"
        mail = Mail.read(path)
        print_headers(mail, eml_id, path) unless opts[:text_only]
        $stdout.puts text_body(mail, markdown: opts[:markdown])
        0
      end

      def parse_options(argv)
        opts = { raw: false, text_only: false, mailmate: false, markdown: false }
        OptionParser.new do |o|
          o.banner = "Usage: mmmessage <id> [--raw|--text-only|--mailmate|--markdown]"
          o.separator ""
          o.separator "<id> can be a local eml-id (e.g. 183715), an RFC Message-ID"
          o.separator "(with or without angle brackets, e.g. <abc@example.com>), or"
          o.separator "a message://%3C...%3E URL. The latter two are portable across"
          o.separator "machines and survive copy/paste between desktop/laptop/iPad."
          o.on("--raw", "Output raw .eml bytes") { opts[:raw] = true }
          o.on("--text-only", "Output decoded body only (no headers block)") { opts[:text_only] = true }
          o.on("--mailmate", "Open in MailMate's UI instead of printing (alias for `mmopen <id>`)") { opts[:mailmate] = true }
          o.on("--markdown", "Render HTML body as clean markdown (no-op for plain-text messages)") { opts[:markdown] = true }
        end.parse!(argv)
        opts
      end

      def usage_error(msg)
        warn "mmmessage: #{msg}"
        warn "Usage: mmmessage <id> [--raw|--text-only|--mailmate|--markdown]"
        warn "  <id> is either an eml-id (digits) or an RFC Message-ID."
        2
      end

      def print_headers(mail, eml_id, path)
        imap_root = Mailmate.config.imap_root
        mailbox = path.sub("#{imap_root}/", "").sub(%r{/Messages/[^/]+\.eml\z}, "")
        $stdout.puts "eml-id:     #{eml_id}"
        $stdout.puts "path:       #{path}"
        $stdout.puts "mailbox:    #{mailbox}"
        $stdout.puts "from:       #{Array(mail.from).join(", ")}" if mail.from
        $stdout.puts "to:         #{Array(mail.to).join(", ")}"   if mail.to
        $stdout.puts "cc:         #{Array(mail.cc).join(", ")}"   if mail.cc
        $stdout.puts "subject:    #{mail.subject}"
        $stdout.puts "date:       #{Mailmate.localize(mail.date)&.iso8601}"
        $stdout.puts "message-id: #{mail.message_id}"
        thread_id = Mailmate::Attributes.thread_id_for(mail)
        $stdout.puts "thread-id:  #{thread_id}" if thread_id
        tags = user_tags(eml_id)
        $stdout.puts "tags:       #{tags.join(", ")}" unless tags.empty?
        if mail.attachments.any?
          $stdout.puts "attachments:"
          mail.attachments.each do |a|
            sz = begin
              a.body.decoded.bytesize
            rescue StandardError
              0
            end
            $stdout.puts "  - #{a.filename || "(no name)"}  #{a.mime_type}  #{sz}b"
          end
        end
        $stdout.puts
      end

      # User tags applied to this message, from MailMate's `#flags` index —
      # tags live there as IMAP keywords, not in the .eml, so the parsed Mail
      # can't see them. Drops `\…` (RFC) and `$…` (Apple/Thunderbird) system
      # flags so only user-facing tags show. Same derivation as mmsearch's
      # `tags` column. Returns [] when the index is missing or the message
      # has none.
      def user_tags(eml_id)
        return [] if eml_id.nil?
        flags = (Mailmate::IndexReader.for("#flags").flags_for(eml_id.to_i) rescue [])
        flags.reject { |f| f.start_with?("\\", "$") }
      end

      def text_body(mail, markdown: false)
        if mail.text_part
          # text/plain is already plain — markdown flag is a no-op here.
          mail.text_part.decoded.force_encoding("UTF-8").scrub
        elsif mail.html_part
          html = mail.html_part.decoded.force_encoding("UTF-8").scrub
          markdown ? html_to_markdown(html) : "[no text/plain part — HTML rendered below; use --raw for original]\n\n#{html}"
        else
          body = mail.body.decoded.to_s.force_encoding("UTF-8").scrub
          if markdown && html_like?(mail, body)
            html_to_markdown(body)
          else
            body
          end
        end
      end

      # Heuristic for "this body is HTML even though Mail couldn't structure it"
      # — covers single-part text/html messages where mail.html_part is nil and
      # we'd otherwise dump the raw markup.
      def html_like?(mail, body)
        ct = mail.content_type.to_s.downcase
        ct.include?("text/html") || body =~ /\A\s*<(?:!doctype html|html|body|head)\b/i
      end

      # HTML → clean markdown for terminal reading. Three preprocessing /
      # postprocessing passes beyond plain reverse_markdown:
      #   1. Drop <style> and <script> blocks before conversion — pure clutter
      #      that reverse_markdown otherwise dumps as inline text.
      #   2. Strip zero-width spacers that newsletters use to control inbox
      #      preview text (U+034F, U+200B/C/D, U+FEFF). Without this, you get
      #      long runs of `͏ ` in the output.
      #   3. Collapse 3+ consecutive blank lines into a single blank line.
      def html_to_markdown(html)
        begin
          require "nokogiri"
          require "reverse_markdown"
        rescue LoadError => e
          warn "mmmessage --markdown needs the reverse_markdown gem (which pulls nokogiri)."
          warn "Install it with:  gem install reverse_markdown"
          warn "(underlying: #{e.message}) — falling back to raw HTML."
          # Degrade to the raw HTML rather than `exit`: a library method must
          # not kill its host, and the in-process MCP server would otherwise
          # die on the SystemExit (its dispatch rescues StandardError only).
          return html
        end
        doc = Nokogiri::HTML(html)
        doc.css("style, script").remove
        md = ReverseMarkdown.convert(doc.to_html)
        # U+034F combining grapheme joiner, U+200B ZWSP, U+200C ZWNJ,
        # U+200D ZWJ, U+FEFF BOM/ZWNBSP — newsletter preview-text padding.
        md.gsub!(/[\u034F\u200B\u200C\u200D\uFEFF]/, "")
        # Convert non-breaking spaces to regular spaces so rstrip can collapse
        # them. Newsletter preview-text padding often uses runs of &nbsp; which
        # Ruby's .rstrip leaves alone otherwise.
        md.gsub!(/[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/, " ")
        # Strip trailing whitespace per line - the spaces between the
        # now-removed zero-width chars otherwise leave long whitespace runs.
        md = md.lines.map(&:rstrip).join("\n")
        md.gsub!(/\n{3,}/, "\n\n")
        md.strip
      end
    end
  end
end
