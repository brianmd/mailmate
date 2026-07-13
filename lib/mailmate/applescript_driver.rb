# frozen_string_literal: true

require "shellwords"

module Mailmate
  # @api public
  #
  # Build and run AppleScript calls against MailMate. macOS-only.
  #
  # A class (not a module like the stateless utilities `HeaderReader`,
  # `MidUrl`, `Identity`, etc.) because each driver carries per-invocation
  # state — `dry_run`, `output`, `errput`. The rule throughout the gem:
  # stateless surface → module with `extend self`; state-bearing → class.
  class AppleScriptDriver
    class Error < StandardError; end

    attr_reader :dry_run

    def initialize(dry_run: false, output: $stdout, errput: $stderr)
      @dry_run = dry_run
      @output  = output
      @errput  = errput
    end

    # Drive a MailMate selector against the current selection.
    # `selector` is the key-binding selector name (`"markAsRead:"`,
    # `"setTag:"`, etc.). `args` are positional arguments passed alongside.
    def perform(selector, *args)
      Mailmate::PlatformError.check_darwin!(component: "AppleScriptDriver") unless dry_run
      script = build_perform_script(selector, args)
      run_apple_script(script)
    end

    # Open a URL in MailMate (used for `mid:` URLs to select a message).
    # Uses `open -g -a MailMate` so the URL is dispatched to MailMate's URL
    # handler without bringing MailMate to the foreground — keeping the
    # user's keyboard focus where it was. The viewer window is still spawned
    # for `mid:` URLs. The AppleScript-native alternative
    # (`tell application "MailMate" to open location`) was tried but is
    # synchronous and can hang on `mid:` URLs while MailMate processes the
    # spawn — `open -g` is asynchronous and avoids the wait.
    def open_url(url)
      Mailmate::PlatformError.check_darwin!(component: "AppleScriptDriver") unless dry_run
      if dry_run
        @output.puts "DRY: open -g -a MailMate #{url.inspect}"
        return
      end
      success = system("/usr/bin/open", "-g", "-a", "MailMate", url)
      raise Error, "open command failed for #{url}" unless success
    end

    # Return the array of MailMate's current window IDs (integers). Empty
    # array if MailMate isn't running or `osascript` errors.
    def window_ids
      return [] if dry_run
      out = `osascript -e 'tell application "MailMate" to get id of every window' 2>&1`
      return [] unless $?.success?
      out.strip.split(",").map { |s| s.strip.to_i }
    end

    # Close every window in `ids`. No-op for IDs that no longer exist.
    def close_windows(ids)
      return if dry_run
      Array(ids).each do |id|
        `osascript -e 'tell application "MailMate" to close window id #{id}' >/dev/null 2>&1`
      end
    end

    # Internal — build the `tell application "MailMate" to perform { ... }`
    # script with proper quoting. AppleScript string literals require:
    #   \ → \\   (single backslash becomes \\, otherwise it interprets
    #             \b / \n / \t / etc. as control-character escapes)
    #   " → \"   (terminates the string otherwise)
    # Newlines and tabs in args are rejected — they have no defensible meaning
    # inside an AppleScript single-line script and almost certainly indicate
    # data the caller doesn't want injected.
    def build_perform_script(selector, args)
      escaped_selector = applescript_escape(selector.to_s, allow_controls: false)
      if args.empty?
        %(tell application "MailMate" to perform {"#{escaped_selector}"})
      else
        list = args.map { |a| %("#{applescript_escape(a.to_s)}") }.join(", ")
        %(tell application "MailMate" to perform {"#{escaped_selector}", #{list}})
      end
    end

    # Escape a Ruby string for inclusion inside an AppleScript double-quoted
    # string literal. Order matters: backslash first, then quote. Newlines/
    # tabs are rejected unless `allow_controls: true`.
    def applescript_escape(s, allow_controls: false)
      if !allow_controls && s.match?(/[\r\n\t]/)
        raise Error, "AppleScript arg contains control character (\\r/\\n/\\t): #{s.inspect}"
      end
      s.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
    end

    private

    def run_apple_script(script)
      if dry_run
        @output.puts "DRY: osascript -e #{script.inspect}"
        return
      end
      output = `osascript -e #{Shellwords.escape(script)} 2>&1`
      status = $?.exitstatus
      @errput.puts "[osascript] #{output.strip}" unless output.strip.empty?
      raise Error, "osascript exited #{status}: #{script}" unless status.zero?
    end
  end
end
