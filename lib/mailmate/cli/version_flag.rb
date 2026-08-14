# frozen_string_literal: true

require_relative "../version"

module Mailmate
  module CLI
    # `--version` / `-V`, handled uniformly by every exe shim.
    #
    # This exists so a CONSUMER can tell how old an installed mailmate is
    # without parsing help text or probing for a flag's side effects. That
    # matters because the CLIs are deliberately pass-through: an older
    # `mm-send` handed a flag it doesn't know forwards it to `emate` rather
    # than rejecting it, so "did this flag work?" is not a safe capability
    # probe — it can open a composer window instead of erroring. A version
    # string is the honest check.
    #
    # Every shim calls this before dispatching, so the answer is available
    # even from commands whose real work needs macOS or a running MailMate.
    # test_exe_shims.rb asserts the coverage is total; a new shim that skips
    # the call fails that test rather than silently becoming the one command
    # that can't be version-probed.
    module VersionFlag
      extend self

      FLAGS = %w[--version -V].freeze

      # Prints "<name> (mailmate X.Y.Z)" and exits 0 when the flag is present.
      # Returns nil otherwise, so shims can call it unconditionally.
      def handle!(argv, name)
        return unless argv.any? { |a| FLAGS.include?(a) }

        $stdout.puts "#{name} (mailmate #{Mailmate::VERSION})"
        exit 0
      end
    end
  end
end
