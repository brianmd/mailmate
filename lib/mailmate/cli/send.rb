# frozen_string_literal: true

require "open3"

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
        Mailmate::PlatformError.check_darwin!(component: "mm-send")
        unless File.executable?(EMATE_PATH)
          warn "mm-send: emate not found at #{EMATE_PATH}. Is MailMate installed?"
          return 1
        end
        help = argv.include?("--help") || argv.include?("-h")
        warn PREAMBLE if help
        # --help never reads a body; consuming stdin here would hang an
        # interactive `mm-send --help` waiting for Ctrl-D.
        body = help ? "" : $stdin.read.to_s
        out, err, status = Open3.capture3(EMATE_PATH, "mailto", "--markup", "markdown", *argv, stdin_data: body)
        $stdout.write(out)
        $stderr.write(err)
        # exitstatus is nil for a signal-killed child; the exe shims do
        # `exit run(ARGV)`, which needs an Integer.
        status.exitstatus || 1
      end
    end
  end
end
