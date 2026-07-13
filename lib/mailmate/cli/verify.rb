# frozen_string_literal: true

require "optparse"
require "json"
require_relative "../flag_check"

module Mailmate
  module CLI
    # `mm-verify` — batch-confirm `mm-modify --emit-check` tickets against the
    # `#flags` index in ONE index-flush wait.
    #
    # MailMate flushes `#flags` to disk a few seconds after an AppleScript
    # action, and it's a single global file. So a batch of N modifies can be
    # confirmed by waiting once for that flush and reading the index once —
    # not by polling per message (which would pay the latency N times). Feed
    # this the tickets `mm-modify --emit-check` printed (a JSON array, or
    # newline-delimited JSON objects); it polls the index until every ticket's
    # expectations hold or --check-timeout elapses, then prints a JSON summary.
    #
    # Exit: 0 all confirmed, 3 one or more failed, 2 bad input.
    # @api private
    module Verify
      extend self

      def run(argv)
        opts = { check_timeout: 8.0, poll: 0.25, pretty: true, file: nil }
        parser = build_parser(opts)
        parser.parse!(argv)

        raw = read_input(opts, argv)
        return usage_error(parser, "no ticket input (pass a file, JSON arg, or pipe on stdin)") if raw.nil? || raw.strip.empty?

        tickets =
          begin
            parse_tickets(raw)
          rescue JSON::ParserError => e
            warn "mm-verify: could not parse tickets as JSON array or NDJSON: #{e.message}"
            return 2
          end
        return usage_error(parser, "no tickets found in input") if tickets.empty?

        summary = verify(tickets, timeout: opts[:check_timeout], poll: opts[:poll])
        $stdout.puts(opts[:pretty] ? JSON.pretty_generate(summary) : JSON.generate(summary))
        summary["failed"].zero? ? 0 : 3
      end

      # Poll the #flags index until every ticket's expectations hold or the
      # timeout elapses; one index read per poll iteration covers the whole
      # batch. Returns the summary Hash.
      def verify(tickets, timeout:, poll:)
        deadline = Time.now + timeout
        started  = Time.now
        results  = nil
        loop do
          results = check_all(tickets)
          break if results.all? { |r| r["ok"] }
          break if Time.now >= deadline
          sleep(poll)
        end
        passed = results.count { |r| r["ok"] }
        {
          "checked"        => results.size,
          "passed"         => passed,
          "failed"         => results.size - passed,
          "waited_seconds" => (Time.now - started).round(2),
          "results"        => results,
        }
      end

      # One pass: read #flags fresh, then evaluate every ticket against it.
      def check_all(tickets)
        reader = fresh_flags_reader
        tickets.map do |t|
          eml_id = t["eml_id"].to_i
          exps   = Array(t["expectations"])
          flags  = reader ? reader.flags_for(eml_id) : []
          unmet  = exps.reject { |kind, arg| Mailmate::FlagCheck.met?(flags, kind, arg) }
          {
            "eml_id"     => eml_id,
            "message_id" => t["message_id"],
            "ok"         => unmet.empty?,
            "flags"      => flags,
            "unmet"      => unmet.map { |kind, arg| Mailmate::FlagCheck.label(kind, arg) },
          }
        end
      end

      # Force a fresh read of #flags (bypass the staleness throttle so each
      # poll sees the latest on-disk state). nil if the index is absent.
      def fresh_flags_reader
        Mailmate::IndexReader.reset!("#flags")
        Mailmate::IndexReader.for("#flags")
      rescue ArgumentError
        nil
      end

      # Accepts a JSON array of ticket objects, or newline-delimited JSON
      # objects (what `mm-modify --emit-check` prints, one per line). A bare
      # single object is wrapped.
      def parse_tickets(raw)
        s = raw.strip
        if s.start_with?("[")
          Array(JSON.parse(s))
        elsif s.start_with?("{") && !s.include?("\n")
          [JSON.parse(s)]
        else
          s.each_line.map(&:strip).reject(&:empty?).map { |line| JSON.parse(line) }
        end
      end

      def read_input(opts, argv)
        return File.read(opts[:file]) if opts[:file]
        return argv.join("\n") unless argv.empty?
        return nil if $stdin.tty?
        $stdin.read
      end

      def build_parser(opts)
        OptionParser.new do |o|
          o.banner = <<~BANNER
            Usage: mm-verify [tickets.json] [options]
                   mm-modify <id> <action> --emit-check | ... | mm-verify

            Confirm a batch of `mm-modify --emit-check` tickets against the #flags
            index, paying the index-flush wait ONCE for the whole batch. Input is a
            JSON array of tickets, or newline-delimited JSON objects, read from a
            file (positional or --file), a JSON argument, or stdin.

            Output: a JSON summary {checked, passed, failed, waited_seconds, results}.
            Exit 0 if all confirmed, 3 if any failed, 2 on bad input.
          BANNER
          o.on("--file PATH", "Read tickets from PATH instead of stdin") { |p| opts[:file] = p }
          o.on("--check-timeout SECONDS", Float, "Max seconds to wait for #flags to reflect the batch (default 8.0)") { |s| opts[:check_timeout] = s }
          o.on("--poll SECONDS", Float, "Index re-read interval while waiting (default 0.25)") { |s| opts[:poll] = s }
          o.on("--compact", "Compact JSON output (default pretty)") { opts[:pretty] = false }
        end
      end

      def usage_error(parser, msg)
        warn "mm-verify: #{msg}"
        warn parser.help
        2
      end
    end
  end
end
