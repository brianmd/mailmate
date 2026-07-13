# frozen_string_literal: true

require "optparse"
require "json"
require_relative "../flag_check"

module Mailmate
  module CLI
    # `mm-modify` — apply AppleScript-driven actions (read, flag, tag, archive,
    # move, …) to a MailMate message by its eml-id.
    #
    # Ports mailmate-modify. Multiple actions in one invocation share a single
    # open+wait cycle so chained operations are batched.
    # @api private
    module Modify
      extend self

      # action → [selector] or [selector, arg-count]. arg-count default 0.
      ACTIONS = {
        "read"       => ["markAsRead:"],
        "unread"     => ["markAsUnread:"],
        "flag"       => [:ensure_flagged],
        "unflag"     => [:ensure_not_flagged],
        "tag"        => ["setTag:", 1],
        "untag"      => ["removeTag:", 1],
        "clear-tags" => ["clearTags:"],
        "archive"    => ["archive:"],
        "junk"       => ["markAsJunk:"],
        "not-junk"   => ["markAsNotJunk:"],
        "mute"       => ["toggleMuteState:"],
        "delete"     => ["deleteMessage:"],
        "move"       => ["moveToMailbox:", 1],
      }.freeze

      def run(argv)
        opts, parser = parse_options(argv)
        input = argv.shift
        return usage_error(parser, "missing <id>") if input.nil? || input.empty?
        return usage_error(parser, "no actions given") if argv.empty?

        actions = parse_actions(argv, parser)
        return 2 if actions.nil?

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

        message_id = Mailmate::HeaderReader.message_id(path)
        unless message_id
          warn "Could not find Message-ID in #{path}"
          return 1
        end

        warn_on_duplicates(message_id, eml_id)

        ok = drive(eml_id, message_id, actions, opts)

        # --emit-check: the action is sent; defer confirmation to a later
        # batched `mm-verify` pass. Emit the ticket as the sole stdout line
        # (operational notes went to stderr via `say`) and exit 0 — there's
        # nothing to fail on yet.
        if opts[:emit_check]
          $stdout.puts JSON.generate(build_check_ticket(eml_id, message_id, actions))
          return 0
        end

        # Exit 3 when an effect check fails — distinct from "couldn't resolve"
        # (1) and "bad usage" (2). The MCP surfaces this as isError, and a
        # caller scripting mm-modify can branch on it.
        ok ? 0 : 3
      end

      # A deferred-verification ticket: the target eml-id plus the #flags
      # expectations its action chain should satisfy once MailMate flushes.
      # Non-flag-verifiable chains (move/archive/delete) carry an empty list,
      # so mm-verify auto-passes them. Symbol kinds are stringified for JSON;
      # mm-verify / FlagCheck.met? resolve either form.
      def build_check_ticket(eml_id, message_id, actions)
        exps = verifiable_expectations(actions) || []
        {
          "eml_id"       => eml_id.to_i,
          "message_id"   => message_id,
          "expectations" => exps.map { |kind, arg| [kind.to_s, arg] },
        }
      end

      # Operational notes go to stderr in --emit-check mode (stdout must be
      # pure JSON for the ticket); otherwise to stdout as before.
      def say(opts, msg)
        (opts[:emit_check] ? $stderr : $stdout).puts(msg)
      end

      def parse_options(argv)
        opts = { verify: false, dry_run: false, settle: 3.5, keep_window: false, check: false, check_timeout: 8.0, emit_check: false }
        parser = OptionParser.new do |o|
          o.banner = <<~BANNER
            Usage: mm-modify <id> <action> [args...] [<action> [args...]]...

            <id> can be a local eml-id (e.g. 183715), an RFC Message-ID (with or
            without angle brackets, e.g. <abc@example.com>), or a message://%3C...%3E
            URL. Quote the Message-ID in your shell so the < > aren't interpreted as
            redirection.

            Selects the message in MailMate (via the `mid:` URL) and runs one or
            more AppleScript key-binding selectors against the now-selected message.
            Multiple actions share one open+wait cycle.

            ACTIONS
              read                          Mark seen (\\Seen)
              unread                        Mark unseen
              flag                          Ensure \\Flagged is set (no-op if already)
              unflag                        Ensure \\Flagged is cleared (no-op if already)
              tag <name>                    Set IMAP keyword <name> (e.g. urgent, $Followup)
              untag <name>                  Remove IMAP keyword <name>
              clear-tags                    Remove all keywords
              archive                       Move to the archive mailbox
              move <mailbox>                Move to a specific mailbox. Bare names like 'Archive'
                                            or 'Folder/Sub' resolve within the same account and
                                            take a fast path (direct .eml rename — no UI, no
                                            focus theft). Mailbox UUIDs and cross-account moves
                                            fall back to the AppleScript driver. Chained with
                                            other actions: tag/flag/etc. run first at the
                                            original location, the rename happens last.
              junk / not-junk               Mark as junk / not junk
              mute                          Toggle mute state
              delete                        Delete (move to trash)
          BANNER
          o.on("--verify", "Print the message's current flags. Works with --dry-run as a post-hoc 'check state' probe (run the action first, then re-run with --dry-run --verify).") { opts[:verify] = true }
          o.on("--dry-run", "Print the actions; don't run") { opts[:dry_run] = true }
          o.on("--settle SECONDS", Float, "Timeout for waiting for MailMate's viewer window to spawn after open_url (default 3.5)") { |s| opts[:settle] = s }
          o.on("--keep-window", "Don't close the spawned message-viewer window") { opts[:keep_window] = true }
          o.on("--check", "Verify flag/tag/read actions actually landed on the TARGET eml-id by polling its #flags index after acting (mismatch → exit 3). This is the only way to detect a `mid:` open that resolved to a different duplicate copy. Opt-in, NOT default: MailMate flushes #flags to disk several seconds after an AppleScript action, so this waits up to --check-timeout (default 8s) for the index to catch up before deciding. Chains containing move/archive/delete/junk aren't flag-verifiable and are skipped.") { opts[:check] = true }
          o.on("--check-timeout SECONDS", Float, "Max seconds to wait for the #flags index to reflect the action when --check is set (default 8.0; the index typically lags ~5s).") { |s| opts[:check_timeout] = s }
          o.on("--emit-check", "Don't verify inline; instead print a one-line JSON check-ticket to stdout ({eml_id, message_id, expectations}) and exit 0 once the action is sent. Collect tickets across a batch of modifies and feed them to `mm-verify` to confirm them all with a SINGLE index-flush wait, instead of paying ~5s per message. Operational notes go to stderr so stdout stays pure JSON.") { opts[:emit_check] = true }
        end
        parser.parse!(argv)
        [opts, parser]
      end

      def parse_actions(argv, parser)
        actions = []
        i = 0
        while i < argv.length
          name = argv[i]
          spec = ACTIONS[name]
          unless spec
            warn "mm-modify: unknown action #{name.inspect}"
            warn parser.help
            return nil
          end
          arg_count = spec.is_a?(Symbol) ? 0 : (spec[1] || 0)
          args = argv[(i + 1)...(i + 1 + arg_count)] || []
          if args.length < arg_count
            warn "mm-modify: action '#{name}' needs #{arg_count} arg(s); got #{args.length}"
            return nil
          end
          actions << [name, spec.first, args]
          i += 1 + arg_count
        end
        actions
      end

      def warn_on_duplicates(message_id, eml_id)
        dup_ids = Mailmate::DuplicateScanner.eml_ids_for(message_id)
        return unless dup_ids.size > 1
        others = dup_ids.reject { |id| id == eml_id.to_i }
        warn "WARNING: Message-ID has #{dup_ids.size} copies in MailMate's tree."
        warn "         You targeted #{eml_id}.eml but the action may land on:"
        warn "           #{others.join(", ")}"
        warn "         (MailMate picks one candidate when resolving `mid:` URLs;"
        warn "          the choice is not deterministic by .eml id.)"
      end

      def drive(eml_id, message_id, actions, opts)
        # Fast-path moves apply ONLY when every requested action is a move.
        # When the chain includes any non-move action (tag, flag, archive, …)
        # we're paying for MailMate's UI anyway, so we let MailMate handle the
        # move in-UI alongside the rest. Why this beats reordering moves to
        # the end of the chain:
        #
        # - The marginal cost of one extra AppleScript `moveToMailbox:` call
        #   is small next to the UI activation we're already eating.
        # - MailMate sees the move it just made — no #source-index staleness
        #   inside the same invocation or for follow-ups.
        # - Simpler mental model: pure-move = silent + fast; mixed = all-UI.
        fast_moves, other = actions.partition { |name, _, _| name == "move" }

        if other.empty? && !fast_moves.empty?
          ok = true
          current_path = Mailmate::EmlLookup.path_for(eml_id)
          fast_moves.each do |_name, selector, args|
            new_path = try_fast_move(eml_id, current_path, args.first, opts)
            if new_path
              current_path = new_path
            else
              # Fast-path declined for this one move (cross-account, target
              # not found, perm error, …) — single UI-driven move as fallback.
              ok &&= drive_via_applescript(eml_id, message_id, [["move", selector, args]], opts)
            end
          end
          ok
        else
          # Mixed chain (or pure non-move chain): everything goes through the
          # AppleScript driver in the user-supplied order.
          drive_via_applescript(eml_id, message_id, actions, opts)
        end
      end

      # Returns the new path on success (or in dry-run, the path we *would*
      # have moved to). Returns nil if the caller should fall back to the
      # AppleScript driver for this action (cross-account, unknown target,
      # permission error, …).
      def try_fast_move(eml_id, current_path, target_spec, opts)
        return nil if current_path.nil?
        account_dir = account_dir_for(current_path)
        return nil if account_dir.nil?

        dest_messages = find_target_in_account(account_dir, target_spec)
        return nil if dest_messages.nil?

        dest_path = File.join(dest_messages, "#{eml_id}.eml")
        if dest_path == current_path
          say(opts, "move (fast): #{eml_id}.eml is already in #{target_spec} — no-op")
          return dest_path
        end

        if opts[:dry_run]
          say(opts, "move (fast, dry-run): would rename")
          say(opts, "  from: #{current_path}")
          say(opts, "  to:   #{dest_path}")
          return dest_path
        end

        File.rename(current_path, dest_path)
        # The #source index still points at the old location until MailMate
        # rescans; bust it so any subsequent path_for in this process re-reads
        # (and eventually picks up MailMate's refreshed value).
        Mailmate::IndexReader.reset!("#source") if defined?(Mailmate::IndexReader)
        say(opts, "move (fast): renamed #{eml_id}.eml → #{relative_to_imap_root(dest_messages)}")
        dest_path
      rescue Errno::EACCES, Errno::EXDEV, Errno::ENOENT, Errno::EEXIST => e
        warn "move (fast): rename failed (#{e.class}: #{e.message}); falling back to AppleScript"
        nil
      end

      # The account directory is the first path segment under imap_root.
      def account_dir_for(path)
        imap_root = Mailmate.config.imap_root
        return nil unless path.start_with?("#{imap_root}/")
        rel = path.sub("#{imap_root}/", "")
        first = rel.split("/", 2).first
        return nil if first.nil? || first.empty?
        File.join(imap_root, first)
      end

      # Resolve `target_spec` to a `.../Messages` directory within `account_dir`.
      # Returns nil if not found unambiguously in the same account — caller
      # should then fall back to AppleScript (which can handle cross-account
      # moves, UUIDs, special mailboxes, etc.).
      def find_target_in_account(account_dir, target_spec)
        spec = target_spec.to_s.sub(%r{/Messages\z}, "").sub(/\.mailbox\z/, "")
        return nil if spec.empty?

        # 1. Exact relative path under the account, each segment .mailbox-suffixed.
        nested = spec.split("/").map { |s| "#{s}.mailbox" }.join("/")
        cand = File.join(account_dir, nested, "Messages")
        return cand if File.directory?(cand)

        # 2. Bare-name match anywhere inside the account.
        matches = Dir.glob(File.join(account_dir, "**", "#{spec}.mailbox", "Messages"))
                     .select { |p| File.directory?(p) }
        case matches.size
        when 0 then nil
        when 1 then matches.first
        else
          warn "move (fast): ambiguous target '#{spec}' in account; matches:"
          matches.each { |m| warn "  #{m}" }
          nil
        end
      end

      def relative_to_imap_root(path)
        root = Mailmate.config.imap_root
        path.start_with?("#{root}/") ? path.sub("#{root}/", "") : path
      end

      def drive_via_applescript(eml_id, message_id, actions, opts)
        driver  = Mailmate::AppleScriptDriver.new(dry_run: opts[:dry_run])
        mid_url = Mailmate::MidUrl.for(message_id)

        # Opening the `mid:` URL displays the message in a viewer, which
        # causes MailMate to mark it `\Seen`. If the caller's action chain
        # neither sets nor clears the read state, snapshot it first and
        # restore after the open so this side-effect doesn't silently
        # change read state. Skip in dry-run — no real open happens.
        preserve_unread = should_preserve_unread?(eml_id, actions, opts)

        windows_before = driver.window_ids
        driver.open_url(mid_url)
        # Active wait: poll for the new viewer window instead of sleeping a
        # fixed `settle`. Windows typically spawn in 200-500ms; the previous
        # fixed 3.5s sleep was wildly conservative. `--settle` now controls
        # the timeout for this wait rather than the sleep duration.
        new_windows = opts[:dry_run] ? [] : wait_for_new_window(driver, windows_before, timeout: opts[:settle])

        # No viewer window means the `mid:` open didn't take (MailMate busy,
        # mid-launch, or the URL didn't resolve) — performing actions now
        # would act on whatever is currently selected, i.e. the wrong message.
        # Retry the open once before proceeding; if it still doesn't spawn,
        # warn loudly. Effect verification below is the backstop for flag
        # actions; for move/archive/delete this warning is the only signal.
        if !opts[:dry_run] && new_windows.empty?
          driver.open_url(mid_url)
          new_windows = wait_for_new_window(driver, windows_before, timeout: opts[:settle])
          if new_windows.empty?
            warn "WARNING: no MailMate viewer window appeared for #{mid_url} (retried once)."
            warn "         The action target is UNCONFIRMED — it may hit the wrong message or no-op."
          end
        end

        # Restore unread BEFORE user actions: a subsequent move / archive /
        # delete moves the message out of the viewer's selection, after
        # which a `markAsUnread:` would land on whatever MailMate selected
        # next (or be a silent no-op).
        if preserve_unread
          say(opts, "preserve-read-state: re-marking #{eml_id}.eml unread (opening the mid: URL marks it read)")
          driver.perform("markAsUnread:")
        end

        # Send each action's selector without sleeping between them.
        # AppleEvents queue per-app and process in order, so a subsequent
        # `close window id N` will execute only after `perform` is committed.
        actions.each do |name, selector, args|
          case selector
          when :ensure_flagged, :ensure_not_flagged
            want  = selector == :ensure_flagged
            flags = opts[:dry_run] ? [] : current_flags(eml_id)
            has   = flags.include?("\\Flagged")
            if has == want
              say(opts, "#{name}: already #{want ? "flagged" : "not flagged"} — no-op")
            else
              driver.perform("toggleFlag:")
            end
          else
            driver.perform(selector, *args)
          end
        end

        # Opt-in effect verification (--check): re-read the TARGET eml-id's
        # flags and confirm the actions actually landed there. This is the
        # only check that catches a `mid:` open resolving to a different
        # duplicate copy — AppleScript can't tell us which message it acted
        # on, but the index can tell us whether OUR eml-id changed.
        #
        # NOT default: MailMate flushes #flags to disk ~5s after an
        # AppleScript write (measured), so verify_effects polls up to
        # check_timeout for the index to catch up. A default-on check would
        # either false-fail (timeout too short) or slow every modify by
        # several seconds (timeout long enough) — neither is acceptable for
        # the common path, so the latency is paid only when asked for.
        # Skipped for location-changing chains (the .eml leaves the viewer).
        verified = true
        if opts[:check] && !opts[:emit_check] && !opts[:dry_run] && (exps = verifiable_expectations(actions))
          verified, flags = verify_effects(eml_id, exps, timeout: opts[:check_timeout])
          if verified
            $stdout.puts "verify: ✓ #{exps.size} effect(s) confirmed on #{eml_id}.eml — flags: #{flags.inspect}"
          else
            warn "verify: ✗ effect check FAILED on #{eml_id}.eml after #{opts[:check_timeout]}s — flags: #{flags.inspect}"
            warn "        Expected: #{exps.map { |k, a| Mailmate::FlagCheck.label(k, a) }.join(", ")}"
            warn "        The action may have landed on a different duplicate copy, or the index"
            warn "        still hasn't flushed. Re-run, or raise --check-timeout."
          end
        end

        # --verify is now permitted in --dry-run mode so callers can use
        # `mm-modify <id> <any-action> --dry-run --verify` as a post-hoc
        # "what's the current flag state?" probe after a separate action run.
        # In non-dry-run mode, a short fixed wait gives MailMate time to
        # flush #flags before we read it back; in dry-run no wait is needed.
        if opts[:verify]
          sleep(1) unless opts[:dry_run]
          say(opts, "Flags now: #{current_flags(eml_id).inspect}")
        end

        unless opts[:keep_window] || opts[:dry_run] || new_windows.empty?
          driver.close_windows(new_windows)
        end

        verified
      end

      # Actions that relocate or destroy the .eml — its #flags record moves
      # or disappears, so post-action flag verification isn't meaningful.
      LOCATION_ACTIONS = %w[move archive delete junk not-junk].freeze

      # Build the set of #flags expectations a chain should satisfy after it
      # runs, or nil when the chain isn't effect-verifiable. Returns nil if:
      #   - any action changes location (move/archive/delete/junk),
      #   - clear-tags is mixed with tag/untag (order-dependent net state we
      #     don't model — bail rather than risk a false failure),
      #   - nothing in the chain is flag-observable.
      # Later actions on the same flag win (last-write); `mute` is ignored
      # (no clean #flags signal) without blocking the rest.
      def verifiable_expectations(actions)
        return nil if actions.any? { |name, _, _| LOCATION_ACTIONS.include?(name) }

        exp = {}
        has_clear = false
        has_tagop = false
        actions.each do |name, _, args|
          case name
          when "read"       then exp[:seen]    = [:seen, true]
          when "unread"     then exp[:seen]    = [:seen, false]
          when "flag"       then exp[:flagged] = [:flagged, true]
          when "unflag"     then exp[:flagged] = [:flagged, false]
          when "tag"        then has_tagop = true; exp["tag:#{args.first}"] = [:tag_present, args.first]
          when "untag"      then has_tagop = true; exp["tag:#{args.first}"] = [:tag_absent, args.first]
          when "clear-tags" then has_clear = true
          end
        end
        return nil if has_clear && has_tagop
        exp[:clear] = [:no_user_tags, nil] if has_clear
        exp.empty? ? nil : exp.values
      end

      # Poll the target eml-id's flags until every expectation holds or the
      # timeout elapses (success returns on the first satisfying read, so the
      # common case is fast; only genuine failures wait out the timeout).
      # Returns [met?, last_flags_seen].
      def verify_effects(eml_id, expectations, timeout:, poll: 0.1)
        deadline = Time.now + timeout
        flags = nil
        loop do
          flags = current_flags(eml_id)
          return [true, flags] if Mailmate::FlagCheck.all_met?(flags, expectations)
          break if Time.now >= deadline
          sleep(poll)
        end
        [false, flags]
      end

      # Thin delegator kept for the unit tests that target the predicate
      # directly; the canonical logic lives in Mailmate::FlagCheck.
      def flag_expectation_met?(flags, kind, arg)
        Mailmate::FlagCheck.met?(flags, kind, arg)
      end

      # Poll for a new MailMate window appearing in `driver.window_ids` that
      # isn't in `windows_before`. Returns the set of new window IDs, or an
      # empty array if `timeout` elapses without a new window appearing.
      def wait_for_new_window(driver, windows_before, timeout:, poll: 0.05)
        deadline = Time.now + timeout
        loop do
          diff = driver.window_ids - windows_before
          return diff unless diff.empty?
          break if Time.now >= deadline
          sleep(poll)
        end
        []
      end

      # True iff we should re-mark the message unread after opening it.
      # - Skip when any user action already touches read state (read/unread)
      #   — the user's chain wins.
      # - Skip in dry-run — no real open, so no real read-flip to undo.
      # - Otherwise: read the index; preserve only if currently unread.
      def should_preserve_unread?(eml_id, actions, opts)
        return false if opts[:dry_run]
        return false if actions.any? { |name, _, _| name == "read" || name == "unread" }
        !current_flags(eml_id).include?("\\Seen")
      end

      def current_flags(eml_id)
        # AppleScript actions write the index asynchronously — bust just the
        # #flags cache to pick up the latest values without throwing away
        # other warmed indexes (#message-id, #source) that this same
        # invocation may still need.
        Mailmate::IndexReader.reset!("#flags")
        Mailmate::IndexReader.for("#flags").flags_for(eml_id.to_i)
      end

      def usage_error(parser, msg)
        warn "mm-modify: #{msg}"
        warn parser.help
        2
      end
    end
  end
end
