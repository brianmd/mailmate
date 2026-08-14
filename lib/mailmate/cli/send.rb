# frozen_string_literal: true

require "open3"
require_relative "../reply_prefill"

module Mailmate
  module CLI
    # `mm-send` — send mail through MailMate's `emate` CLI with a markdown body.
    # Replaces the 6-line bash wrapper that previously lived at
    # ~/.claude/skills/email/send-email. All flags pass through to `emate
    # mailto`; `--markup markdown` is enforced.
    # @api private
    module Send
      extend self

      EMATE_PATH = "/Applications/MailMate.app/Contents/Resources/emate"

      PREAMBLE = <<~PREAMBLE
        mm-send — thin wrapper around `emate mailto` with `--markup markdown` enforced.
        Body is read from stdin. All other flags pass through to emate (its help follows).

        Replies and threading
          A `Re:` subject alone does NOT thread — modern clients thread on headers.
          MailMate generates the outgoing Message-ID; never your job.

            mm-send -f you@x --reply-to "<parent-mid@domain>" --send-now <<<"body"

          derives In-Reply-To, References, recipients and subject from the parent.
          --reply-all-to replies to all; --forward forwards. Fields you pass
          explicitly win; fields you omit follow normal reply rules. --header
          stays available as the escape hatch when the parent isn't indexed.

        Identity selection
          `-f <address>` picks which of MailMate's configured identities sends.
          Without `-f`, MailMate uses its default identity. See `mmdiscover` to
          list available addresses.

        Full rules — threading chain, merge rule, header safety:
          docs/Composing and threading.md (shipped with the gem), or
          https://github.com/brianmd/mailmate/blob/main/docs/

        ──────────────────────────── emate help follows ────────────────────────────

      PREAMBLE

      # Returns the exit status of the spawned `emate` invocation.
      #
      # emate must NEVER inherit the caller's real stdin/stdout. Inside the
      # MCP server, fd 0/1 are the JSON-RPC transport, and the previous
      # `system(...)` handed both to emate: it blocked reading the protocol
      # pipe for a body and consumed the next frame as one (a cancelled turn
      # produced a MailMate draft whose entire body was a
      # `notifications/cancelled` frame — the composed body, swapped in via
      # the Ruby-level `$stdin` global, was silently discarded). So: read the
      # body through `$stdin` (honors the MCP's StringIO swap AND a shell
      # pipe), hand it to emate on a private pipe that capture3 EOFs (no
      # more hanging until the server dies), and re-emit emate's output
      # through the `$stdout`/`$stderr` globals so the MCP's capture sees it
      # instead of the protocol stream getting corrupted.
      def run(argv)
        help = argv.include?("--help") || argv.include?("-h")

        # Our own flags are peeled off BEFORE the platform/emate checks so
        # `--print-prefill` works as a pure query — markdownr calls it to fill
        # a form and has no business requiring a launchable MailMate.
        begin
          argv, derived = apply_parent!(argv, help: help)
        rescue Mailmate::ReplyPrefill::NotFound, ArgumentError => e
          warn "mm-send: #{e.message}"
          return 1
        end
        return print_prefill(derived) if derived && derived[:print_only]

        Mailmate::PlatformError.check_darwin!(component: "mm-send")
        unless File.executable?(EMATE_PATH)
          warn "mm-send: emate not found at #{EMATE_PATH}. Is MailMate installed?"
          return 1
        end
        warn PREAMBLE if help
        # --help never reads a body; consuming stdin here would hang an
        # interactive `mm-send --help` waiting for Ctrl-D.
        body = help ? "" : $stdin.read.to_s
        body = append_quote(body, derived) if derived
        out, err, status = Open3.capture3(EMATE_PATH, "mailto", "--markup", "markdown", *argv, stdin_data: body)
        $stdout.write(out)
        $stderr.write(err)
        # exitstatus is nil for a signal-killed child; the exe shims do
        # `exit run(ARGV)`, which needs an Integer.
        status.exitstatus || 1
      end

      # Flags this wrapper consumes itself. Everything else in argv is emate's
      # and passes through untouched — that pass-through is the design, so the
      # scan below is deliberately literal rather than an OptionParser (which
      # would have to be taught every emate flag in order to ignore them).
      PARENT_FLAGS = { "--reply-to" => "reply", "--reply-all-to" => "reply-all", "--forward" => "forward" }.freeze

      # Returns [argv_for_emate, derived_or_nil]. When a parent flag is
      # present, derives the reply fields and splices them in as emate flags —
      # but only for fields the caller did NOT pass. Explicit always wins; see
      # the merge rule in docs/Composing and threading.md.
      def apply_parent!(argv, help: false)
        rest, parent, mode, print_only, quote = extract_flags(argv)
        return [rest, nil] if parent.nil?

        # --print-prefill is a query, so it answers even under --help; the
        # send path would otherwise be unreachable for a caller inspecting it.
        prefill = Mailmate::ReplyPrefill.build(parent, mode: mode)
        derived = { prefill: prefill, print_only: print_only, quote: quote }
        return [rest, derived] if print_only || help

        [splice(rest, prefill), derived]
      end

      def extract_flags(argv)
        rest = []
        parent = mode = nil
        print_only = false
        quote = true
        i = 0
        while i < argv.length
          arg = argv[i]
          if PARENT_FLAGS.key?(arg)
            raise ArgumentError, "#{arg} needs a message id" if argv[i + 1].nil?
            raise ArgumentError, "pass only one of #{PARENT_FLAGS.keys.join(', ')}" if parent

            mode = PARENT_FLAGS[arg]
            parent = argv[i + 1]
            i += 2
          elsif arg == "--print-prefill"
            print_only = true
            i += 1
          elsif arg == "--no-quote"
            quote = false
            i += 1
          else
            rest << arg
            i += 1
          end
        end
        raise ArgumentError, "--print-prefill needs one of #{PARENT_FLAGS.keys.join(', ')}" if print_only && parent.nil?

        [rest, parent, mode, print_only, quote]
      end

      # Add derived values ONLY where the caller was silent. `passed?` looks
      # for the flag itself, so `-t a@x --reply-to <id>` keeps a@x and still
      # threads — overriding a visible field must never drop the headers.
      def splice(argv, prefill)
        out = argv.dup
        out.push("-f", prefill.from) if prefill.from && !passed?(argv, %w[-f --from])
        unless passed?(argv, %w[-t --to])
          prefill.to.each { |a| out.push("-t", a) }
        end
        unless passed?(argv, %w[-c --cc])
          prefill.cc.each { |a| out.push("-c", a) }
        end
        out.push("-s", prefill.subject) if prefill.subject && !passed?(argv, %w[-s --subject])
        # Threading headers are NOT subject to the merge rule's "explicit
        # wins" in the usual sense — a caller who passes their own
        # --header "In-Reply-To: …" alongside --reply-to gets both, which is
        # a duplicate header. Skip ours when they've hand-set either one.
        out.push("--header", "In-Reply-To: #{prefill.in_reply_to}") if prefill.in_reply_to && !header_passed?(argv, "in-reply-to")
        out.push("--header", "References: #{prefill.references}")   if prefill.references && !header_passed?(argv, "references")
        out
      end

      def passed?(argv, flags)
        argv.any? { |a| flags.include?(a) || flags.any? { |f| f.start_with?("--") && a.start_with?("#{f}=") } }
      end

      def header_passed?(argv, name)
        argv.each_with_index.any? do |a, i|
          (a == "--header" && argv[i + 1].to_s.downcase.start_with?("#{name}:")) ||
            (a.start_with?("--header=") && a.split("=", 2).last.to_s.downcase.start_with?("#{name}:"))
        end
      end

      # Reply rules seed the body with the quoted original BELOW whatever the
      # caller wrote, matching what a mail client's Reply button produces.
      def append_quote(body, derived)
        return body unless derived[:quote]

        quote = derived[:prefill].quoted_body.to_s
        return body if quote.strip.empty?

        "#{body.to_s.sub(/\n+\z/, '')}\n\n#{quote}"
      end

      def print_prefill(derived)
        require "json"
        $stdout.puts JSON.pretty_generate(derived[:prefill].to_h)
        0
      end
    end
  end
end
