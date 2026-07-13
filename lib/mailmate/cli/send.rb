# frozen_string_literal: true

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
          MailMate auto-generates the outgoing Message-ID — never your job.
          In-Reply-To and References are PURE PASS-THROUGH: whatever you set via
          `--header` ships verbatim; what you don't set is absent (and recipients'
          clients will see the message as a fresh thread, no matter how `Re:` the
          subject looks). To make a reply land in-thread, pass both:

            mm-send -f you@x -t them@y -s "Re: foo" \\
              --header "In-Reply-To: <parent-message-id@domain>" \\
              --header "References: <root-mid> <parent-mid>" \\
              --send-now <<<"body"

          References is constructed as the source message's References header (if
          any) with the source's Message-ID appended. If the source is a thread
          root with no References, just use its Message-ID alone.

        Identity selection
          `-f <address>` picks which of MailMate's configured identities sends.
          Without `-f`, MailMate uses its default identity. See `mmdiscover` to
          list available addresses.

        ──────────────────────────── emate help follows ────────────────────────────

      PREAMBLE

      # Returns the exit status of the spawned `emate` invocation. Uses
      # `system` (not `exec`) so the caller — and the test suite — can
      # actually observe the result.
      def run(argv)
        Mailmate::PlatformError.check_darwin!(component: "mm-send")
        unless File.executable?(EMATE_PATH)
          warn "mm-send: emate not found at #{EMATE_PATH}. Is MailMate installed?"
          return 1
        end
        warn PREAMBLE if argv.include?("--help") || argv.include?("-h")
        system(EMATE_PATH, "mailto", "--markup", "markdown", *argv)
        $?.exitstatus
      end
    end
  end
end
