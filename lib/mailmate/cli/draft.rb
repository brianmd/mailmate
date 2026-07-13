# frozen_string_literal: true

require "mailmate/cli/send"

module Mailmate
  module CLI
    # `mm-draft` — identical to `mm-send` but guaranteed never to actually
    # send. It refuses `--send-now` with a nonzero exit, so a "compose this
    # but don't send it" instruction can't be silently defeated by the flag
    # that flips `emate mailto` from draft-pause to send. Without `--send-now`
    # both commands behave identically (open a draft window in MailMate); the
    # only difference is that mm-draft *cannot* be talked into sending.
    # @api private
    module Draft
      extend self

      NOTE = <<~NOTE
        mm-draft — same as `mm-send`, but it only ever opens a draft and refuses
        `--send-now`. Use `mm-send` when you actually want to send. All other
        flags pass through to `emate mailto` exactly as in mm-send (its help
        follows below).

      NOTE

      # Returns the exit status. Refuses `--send-now` (exit 2); otherwise
      # delegates verbatim to `Mailmate::CLI::Send`.
      def run(argv)
        if argv.include?("--send-now")
          warn "mm-draft: refusing --send-now — mm-draft only ever creates drafts. Use mm-send to send."
          return 2
        end
        warn NOTE if argv.include?("--help") || argv.include?("-h")
        Send.run(argv)
      end
    end
  end
end
