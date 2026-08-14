# frozen_string_literal: true

require "json"
require "stringio"

require "mailmate"
require "mailmate/cli/search"
require "mailmate/cli/message"
require "mailmate/cli/modify"
require "mailmate/cli/verify"
require "mailmate/cli/send"
require "mailmate/cli/draft"
require "mailmate/cli/open"
require "mailmate/cli/mailboxes"
require "mailmate/cli/tags"
require "mailmate/eml_lookup"
require "mailmate/header_reader"
require "mailmate/mid_url"

module Mailmate
  # Stdio MCP server (JSON-RPC 2.0, line-delimited). Exposes the gem's CLIs —
  # search, message, modify, send, draft — plus a resolve_id helper that round-trips
  # between local eml-id, RFC Message-ID, and the cross-machine message:// URL.
  #
  # In-process: each tool call runs the corresponding `Mailmate::CLI::*.run`
  # method with a synthesized argv, capturing stdout/stderr from the existing
  # CLI rather than re-implementing each command.
  module MCP
    extend self

    PROTOCOL_VERSION = "2024-11-05"
    SERVER_NAME      = "mailmate"

    # Server-level guidance returned from `initialize`. This is the gem's
    # operational doctrine — the things a caller must know to drive MailMate
    # correctly that don't fit in a single tool's description. It travels with
    # the gem so the MCP is self-sufficient (no companion skill required).
    INSTRUCTIONS = <<~INSTRUCTIONS.strip
      Read and act on MailMate's local mail store on macOS. `search`, `message`,
      `resolve_id`, and `list_*` are read-only; `send`, `draft`, `modify`, and
      `open` require MailMate to be running (they drive the app).

      Composing (send / draft)
      - Bodies are Markdown; MailMate renders them to HTML on the way out. For
        that to reach recipients, MailMate → Preferences → Composer must have
        "Preview: Display" = Always and "Replying/Forwarding HTML" = Always
        embed — otherwise recipients get plain text. These are global, one-time
        settings.
      - Set `from` explicitly. When the To: address matches one of the user's
        own accounts, MailMate may otherwise send from that account.
      - Prefer `draft` over `send` whenever the user said "don't send" / "just
        draft it" — `draft` physically cannot send, so it's the safe choice.
        `send` also opens a draft and waits unless you pass `send_now: true`.
      - Replying: pass `reply_to` (the parent's eml-id or Message-ID) and the
        threading headers, recipient and "Re:" subject are derived for you.
        `reply_all_to` replies to all; `forward` forwards (supply `to`).
        Fields you also pass explicitly win; ones you omit follow normal
        reply rules. Prefer this over hand-setting in_reply_to/references —
        a mis-built References chain sends fine and simply doesn't thread,
        and nothing in your own view reveals it. A "Re:" subject alone never
        threads. MailMate generates the outgoing Message-ID itself.
        Full rules — the References chain, the merge rule, header safety —
        are in the gem's docs/Composing and threading.md
        (github.com/brianmd/mailmate), which is canonical; this summary
        exists only so you need not follow a link mid-call.

      Modifying (modify)
      - Drives MailMate's UI via AppleScript: it briefly takes focus, calls are
        serial per app, and each call costs a few seconds (flag/tag writes are
        async). Batch multiple actions into ONE call rather than many.
      - Opening a message marks it \\Seen; read state is auto-preserved unless
        your action chain itself includes read/unread.
      - A Message-ID can live in several mailboxes (Sent + Received copies,
        Gmail label copies). When it does, the action may land on a different
        copy than the id you targeted.

      Identifiers
      - Tools accept a local eml-id (an integer; per-machine, NOT portable) or
        an RFC Message-ID (portable across machines). Use `resolve_id` to
        convert between them and to mint a cross-machine message:// URL.
    INSTRUCTIONS

    TOOLS = [
      {
        name: "search",
        title: "Search mail",
        annotations: { title: "Search mail", readOnlyHint: true },
        description: <<~DESC.strip,
          Search MailMate's .eml files using MailMate's quicksearch syntax.
          Returns column-aligned CSV. Same engine as the `mmsearch` CLI.

          The only native key:value specs are the state forms below
          (is:unread, has:attachment). Other familiar foreign tokens
          (`from:bob`, `date:today`, `after:2026-08-01`, `older_than:2w`) are
          auto-translated to quicksearch, and the rewrite is announced in the
          result — that announcement means your query was translated, not
          that it failed. Unrecognized keys (`in:inbox`, `filename:pdf`) are
          searched as literal text and match nothing, silently.

          #{Mailmate::SearchSyntax.reference(indent: "  ")}

          The `mailbox` arg also accepts a smart-mailbox name (e.g. Newsletters,
          Receipts, Priority) whose filter is ANDed into the search.

          Fields default to: flags date time direction party subject.
          Prefix with "+" to add to the defaults ("+tags +mailbox"); a bare
          list replaces them (id is always the first column). Meanings:
            flags      2 chars — archive-state (A archived / P primary) then
                       read-state (R read / U unread), e.g. AR, PU
            direction  → outbound / ← inbound      party  the other party
            read       R/U      archive  A/P       (standalone flag columns)
          Other fields (from/to/cc/bcc/reply-to/subject/date/time/message-id/
          path/mailbox) are the obvious header or location values.
        DESC
        inputSchema: {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "Quicksearch expression. Empty string disables filtering. Default: 'd 1d' (today).",
            },
            fields: {
              type: "string",
              description: "Space-separated columns. Prefix with '+' to add to defaults. Available: id path mailbox from to cc bcc reply-to subject date time message-id references in-reply-to direction party flags read archive tags keywords.",
            },
            mailbox: {
              type: "string",
              description: "Account, mailbox path, or smart-mailbox name. Default: all.",
            },
            limit: { type: "integer", description: "Stop after N matches." },
            headers_only: { type: "boolean", description: "Skip body matching (much faster on text searches)." },
            sort: { type: "string", enum: %w[asc desc none], description: "Sort by date+time. Default: asc." },
            european: { type: "boolean", description: "Slash dates in the query are day-first (d 9/8/2026 = Aug 9). Default: month-first American." },
          },
          additionalProperties: false,
        },
      },
      {
        name: "message",
        title: "Read message",
        annotations: { title: "Read message", readOnlyHint: true },
        description: "Read one MailMate message. Accepts either local eml-id (digits) or RFC Message-ID (with or without angle brackets). Default output: headers block (incl. any user tags) + plain-text body. For HTML-only mail (most newsletters), pass markdown:true to get clean readable markdown instead of raw HTML — strongly preferred for reading and far more token-efficient; it's a no-op on plain-text messages.",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string", description: "eml-id (e.g. '183715') or RFC Message-ID (e.g. '<abc@example.com>')." },
            raw: { type: "boolean", description: "Return raw .eml bytes." },
            text_only: { type: "boolean", description: "Body only, no headers block." },
            markdown: { type: "boolean", description: "Render an HTML-only body as clean markdown (drops <style>/<script>, strips newsletter spacer chars). No-op for plain-text messages." },
          },
          required: ["id"],
          additionalProperties: false,
        },
      },
      {
        name: "modify",
        title: "Modify message state",
        annotations: { title: "Modify message state", readOnlyHint: false, destructiveHint: true },
        description: <<~DESC.strip,
          Apply state-change actions to a message via MailMate.
          NOTE: drives MailMate's UI via AppleScript — it briefly takes focus,
          and calls are serial per app.

          actions is a flat array; arg-taking actions consume the next item:
            ["read"]                       mark read
            ["read", "flag", "archive"]    three actions, one open/wait cycle
            ["tag", "urgent"]              add tag
            ["untag", "todo"]              remove tag
            ["move", "Archive.mailbox"]    move

          Valid actions: read unread flag unflag tag untag clear-tags archive
          junk not-junk mute delete move

          Verifying the action landed (it can't be read back from MailMate, so
          this re-reads the target eml-id's #flags index — the only way to catch
          a Message-ID that resolved to a different duplicate copy):
            check:"inline"  confirm now, before returning (failed → isError).
                            Costs a few seconds — MailMate flushes #flags ~5s
                            after acting. Use for a high-stakes single mutation.
            check:"defer"   don't wait; return a JSON check-ticket instead.
                            Collect tickets across a batch, then pass them to the
                            `verify` tool to confirm them ALL with one flush-wait
                            (the efficient choice for bulk work — 50 modifies pay
                            the ~5s latency once, not 50 times).
            check:"none"    (default) fire-and-forget.
          Location-changing chains (move/archive/delete) aren't flag-verifiable.
        DESC
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string", description: "eml-id or RFC Message-ID." },
            actions: {
              type: "array",
              items: { type: "string" },
              description: "Flat list of action tokens; arg-taking actions consume the following item.",
            },
            dry_run: { type: "boolean", description: "Print plan, don't execute." },
            verify: { type: "boolean", description: "Print the message's current flags after acting (raw probe)." },
            check: { type: "string", enum: %w[none inline defer], description: "Effect-verification mode (default none). 'inline' confirms now (slow, returns isError on failure); 'defer' returns a JSON ticket for batched verification via the `verify` tool." },
            keep_window: { type: "boolean", description: "Skip the close-window keystroke at the end." },
          },
          required: %w[id actions],
          additionalProperties: false,
        },
      },
      {
        name: "verify",
        title: "Verify modify results",
        annotations: { title: "Verify modify results", readOnlyHint: true },
        description: <<~DESC.strip,
          Batch-confirm `modify` check-tickets (from check:"defer") against the
          #flags index in ONE flush-wait. Pass the tickets you collected from a
          run of deferred modifies; this polls the index until every ticket's
          expected flag/tag/read state holds (or check_timeout elapses) and
          returns a JSON summary {checked, passed, failed, waited_seconds,
          results:[{eml_id, ok, flags, unmet}]}. isError if any ticket failed —
          a failure means that action didn't land on that eml-id (wrong
          duplicate copy, or it never registered).
        DESC
        inputSchema: {
          type: "object",
          properties: {
            tickets: {
              type: "array",
              items: { type: "object" },
              description: "The check-ticket objects returned by modify calls made with check:\"defer\".",
            },
            check_timeout: { type: "number", description: "Max seconds to wait for #flags to reflect the batch (default 8)." },
          },
          required: ["tickets"],
          additionalProperties: false,
        },
      },
      {
        name: "send",
        title: "Send mail",
        annotations: { title: "Send mail", readOnlyHint: false, destructiveHint: true },
        description: "Send mail via MailMate's `emate` (markdown body). Recipients and subject via fields; body is the markdown source. For replies, set `in_reply_to` and `references` so recipients' clients thread the message — without them a `Re:` subject alone is not enough. MailMate generates the outgoing Message-ID automatically.",
        inputSchema: {
          type: "object",
          properties: {
            from: { type: "string", description: "Sender identity (one of MailMate's configured addresses; see mmdiscover). If omitted, MailMate uses its default identity." },
            to: { type: "string", description: "Recipient(s), comma-separated." },
            cc: { type: "string", description: "CC recipient(s), comma-separated." },
            bcc: { type: "string", description: "BCC recipient(s), comma-separated." },
            subject: { type: "string", description: "Subject line." },
            body: { type: "string", description: "Markdown body." },
            attachments: { type: "array", items: { type: "string" }, description: "Absolute paths to files to attach." },
            reply_to: { type: "string", description: "Parent message to reply to — eml-id or RFC Message-ID. PREFER THIS over setting in_reply_to/references by hand: it derives In-Reply-To, the full References chain, the recipient and a \"Re:\" subject from the parent. Fields you also pass explicitly win; ones you omit follow normal reply rules." },
            reply_all_to: { type: "string", description: "Same as reply_to but replies to all — adds the other recipients, minus the user own identities." },
            forward: { type: "string", description: "Parent message to forward — eml-id or RFC Message-ID. Derives a \"Fwd:\" subject and the forwarded block; you supply `to`. A forward deliberately does NOT thread into the original conversation." },
            quote: { type: "boolean", description: "Include the quoted original when replying/forwarding (default true). Set false to send only your own text." },
            in_reply_to: { type: "string", description: "Message-ID of the parent message (with or without angle brackets). Sets the In-Reply-To header on the outgoing message so recipients' clients thread it correctly." },
            references: { type: "string", description: "Space-separated chain of Message-IDs (with angle brackets). Conventionally: parent's References header + parent's Message-ID. Required alongside in_reply_to for clean threading in deep chains." },
            send_now: { type: "boolean", description: "Send immediately (skip the Drafts pause)." },
          },
          required: %w[body],
          additionalProperties: false,
        },
      },
      {
        name: "draft",
        title: "Compose draft",
        annotations: { title: "Compose draft", readOnlyHint: false, destructiveHint: false },
        description: "Compose a draft via MailMate's `emate` (markdown body) — IDENTICAL to `send` but it never sends: the draft opens in MailMate and waits. There is no `send_now` option; use this whenever the instruction is 'write/compose but don't send'. For replies, set `in_reply_to` and `references` so the draft threads correctly. MailMate generates the outgoing Message-ID automatically.",
        inputSchema: {
          type: "object",
          properties: {
            from: { type: "string", description: "Sender identity (one of MailMate's configured addresses; see mmdiscover). If omitted, MailMate uses its default identity." },
            to: { type: "string", description: "Recipient(s), comma-separated." },
            cc: { type: "string", description: "CC recipient(s), comma-separated." },
            bcc: { type: "string", description: "BCC recipient(s), comma-separated." },
            subject: { type: "string", description: "Subject line." },
            body: { type: "string", description: "Markdown body." },
            attachments: { type: "array", items: { type: "string" }, description: "Absolute paths to files to attach." },
            reply_to: { type: "string", description: "Parent message to reply to — eml-id or RFC Message-ID. PREFER THIS over setting in_reply_to/references by hand: it derives In-Reply-To, the full References chain, the recipient and a \"Re:\" subject from the parent. Fields you also pass explicitly win; ones you omit follow normal reply rules." },
            reply_all_to: { type: "string", description: "Same as reply_to but replies to all — adds the other recipients, minus the user own identities." },
            forward: { type: "string", description: "Parent message to forward — eml-id or RFC Message-ID. Derives a \"Fwd:\" subject and the forwarded block; you supply `to`. A forward deliberately does NOT thread into the original conversation." },
            quote: { type: "boolean", description: "Include the quoted original when replying/forwarding (default true). Set false to send only your own text." },
            in_reply_to: { type: "string", description: "Message-ID of the parent message (with or without angle brackets). Sets the In-Reply-To header so recipients' clients thread it correctly." },
            references: { type: "string", description: "Space-separated chain of Message-IDs (with angle brackets). Conventionally: parent's References header + parent's Message-ID. Required alongside in_reply_to for clean threading in deep chains." },
          },
          required: %w[body],
          additionalProperties: false,
        },
      },
      {
        name: "open",
        title: "Open in MailMate",
        annotations: { title: "Open in MailMate", readOnlyHint: false, destructiveHint: false },
        description: "Open one MailMate message in MailMate's UI (activates the window). Accepts any of the id forms `resolve_id` takes. Read-side semantically, but does shift focus to MailMate.",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string", description: "eml-id, RFC Message-ID, message://… URL, or mid:… URL." },
            print_only: { type: "boolean", description: "Return the mid: URL without invoking `open`." },
          },
          required: ["id"],
          additionalProperties: false,
        },
      },
      {
        name: "list_mailboxes",
        title: "List mailboxes",
        annotations: { title: "List mailboxes", readOnlyHint: true },
        description: "Enumerate accounts, IMAP mailboxes (with optional message counts), and smart mailboxes MailMate has defined. Account names are decoded for display (`%40` → `@`).",
        inputSchema: {
          type: "object",
          properties: {
            count: { type: "boolean", description: "Include .eml counts per IMAP mailbox (default true; pass false to skip for speed)." },
            csv:   { type: "boolean", description: "Flat CSV output (one row per mailbox); default is grouped by account." },
          },
          additionalProperties: false,
        },
      },
      {
        name: "list_tags",
        title: "List tags",
        annotations: { title: "List tags", readOnlyHint: true },
        description: "List user tags. Default: tags actually applied to messages, with usage counts (from MailMate's #flags index; system flags excluded). `defined: true`: tags MailMate has registered in Preferences → Tags (from Tags.plist).",
        inputSchema: {
          type: "object",
          properties: {
            defined: { type: "boolean", description: "Read from Tags.plist (defined tags) instead of scanning #flags (used tags)." },
          },
          additionalProperties: false,
        },
      },
      {
        name: "resolve_id",
        title: "Resolve message identifiers",
        annotations: { title: "Resolve message identifiers", readOnlyHint: true },
        description: <<~DESC.strip,
          Look up a message and return all its identifiers:
            - eml_id        local body-part id (changes per machine)
            - message_id    RFC Message-ID header (portable across machines)
            - message_url   message://%3C<MID>%3E   — cross-machine reference
            - mid_url       mid:%3C<MID>%3E         — drives MailMate locally

          Accepts: eml-id, Message-ID (with/without angle brackets), or message:// URL.
          Use to mint a portable reference from a local eml-id, or to find the
          local eml-id given a Message-ID copied from another machine.
        DESC
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string", description: "eml-id, Message-ID, or message:// URL." },
          },
          required: ["id"],
          additionalProperties: false,
        },
      },
    ].freeze

    def run(stdin: $stdin, stdout: $stdout)
      stdin.binmode
      stdout.binmode
      stdout.sync = true
      loop do
        line = stdin.gets
        break if line.nil?
        line = line.strip
        next if line.empty?
        begin
          msg = JSON.parse(line)
        rescue JSON::ParserError => e
          write(stdout, jsonrpc_error(nil, -32700, "Parse error: #{e.message}"))
          next
        end
        handle(msg, stdout)
      end
      0
    end

    def handle(msg, stdout)
      method = msg["method"]
      id     = msg["id"]
      case method
      when "initialize"
        write(stdout, jsonrpc_result(id, {
          protocolVersion: PROTOCOL_VERSION,
          capabilities:    { tools: {} },
          serverInfo:      { name: SERVER_NAME, version: Mailmate::VERSION },
          instructions:    INSTRUCTIONS,
        }))
      when "notifications/initialized", "notifications/cancelled"
        # notifications — no response
      when "tools/list"
        write(stdout, jsonrpc_result(id, { tools: TOOLS }))
      when "tools/call"
        params = msg["params"] || {}
        result = dispatch(params["name"], params["arguments"] || {})
        write(stdout, jsonrpc_result(id, result))
      when "ping"
        write(stdout, jsonrpc_result(id, {}))
      else
        # Unknown method — error if it has an id (request), drop if not.
        write(stdout, jsonrpc_error(id, -32601, "Method not found: #{method}")) unless id.nil?
      end
    end

    def dispatch(name, args)
      case name
      when "search"         then call_search(args)
      when "message"        then call_message(args)
      when "modify"         then call_modify(args)
      when "verify"         then call_verify(args)
      when "send"           then call_send(args)
      when "draft"          then call_draft(args)
      when "open"           then call_open(args)
      when "list_mailboxes" then call_list_mailboxes(args)
      when "list_tags"      then call_list_tags(args)
      when "resolve_id"     then call_resolve(args)
      else                       text_error("Unknown tool: #{name}")
      end
    rescue StandardError => e
      text_error("#{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}")
    rescue SystemExit => e
      # A CLI path that calls exit/abort (e.g. a missing optional gem) must
      # not take down the persistent server — surface it as a tool error and
      # keep the loop alive. SystemExit isn't a StandardError, so it needs
      # its own clause.
      text_error("Tool '#{name}' called exit(#{e.status}) — treated as failure, server still running.")
    end

    # ---- tool handlers ----------------------------------------------------

    def call_search(args)
      argv = []
      argv.push("--mailbox", args["mailbox"].to_s)   if args["mailbox"]
      argv.push("--limit",   args["limit"].to_i.to_s) if args["limit"]
      argv.push("--headers-only")                    if args["headers_only"]
      argv.push("--sort",    args["sort"].to_s)      if args["sort"]
      argv.push("--european")                        if args["european"]
      # Positionals: search-string then fields. Only include if the caller
      # gave us either — otherwise let the CLI apply its defaults.
      if args.key?("query") || args["fields"]
        argv << (args["query"] || "")
        argv << args["fields"].to_s if args["fields"]
      end
      run_cli(Mailmate::CLI::Search, argv)
    end

    def call_message(args)
      argv = [args["id"].to_s]
      argv << "--raw"       if args["raw"]
      argv << "--text-only" if args["text_only"]
      argv << "--markdown"  if args["markdown"]
      run_cli(Mailmate::CLI::Message, argv)
    end

    def call_modify(args)
      argv = [args["id"].to_s] + Array(args["actions"]).map(&:to_s)
      argv << "--dry-run"     if args["dry_run"]
      argv << "--verify"      if args["verify"]
      case args["check"]
      when "inline" then argv << "--check"
      when "defer"  then argv << "--emit-check"
      end
      argv << "--keep-window" if args["keep_window"]
      run_cli(Mailmate::CLI::Modify, argv)
    end

    # Batch-verify deferred check-tickets. Tickets arrive as JSON objects;
    # pipe them to mm-verify on stdin (the same array-or-NDJSON it reads
    # from the CLI).
    def call_verify(args)
      argv = []
      argv.push("--check-timeout", args["check_timeout"].to_s) if args["check_timeout"]
      payload = JSON.generate(Array(args["tickets"]))
      with_stdin(payload) { run_cli(Mailmate::CLI::Verify, argv) }
    end

    # `to` and `subject` used to be schema-required, which stopped working the
    # moment a parent could supply them. JSON Schema can't say "required
    # unless another field is present", so the check moved here — dropping it
    # entirely would let a `to`-less call through to open an empty composer.
    def recipient_check(args)
      return nil if args["to"] || args["reply_to"] || args["reply_all_to"]
      return nil if args["forward"] && args["to"]

      text_error("no recipient: pass `to`, or `reply_to`/`reply_all_to` to derive it from the parent. " \
                 "(`forward` derives the subject and body but not the recipient — pass `to` with it.)")
    end

    def call_send(args)
      (err = recipient_check(args)) and return err

      argv = compose_argv(args)
      argv << "--send-now" if args["send_now"]
      with_stdin(args["body"].to_s) { run_cli(Mailmate::CLI::Send, argv) }
    end

    # `draft` mirrors `send` but never sends — it has no send_now option and
    # routes through CLI::Draft, which refuses `--send-now` outright.
    def call_draft(args)
      (err = recipient_check(args)) and return err

      argv = compose_argv(args)
      with_stdin(args["body"].to_s) { run_cli(Mailmate::CLI::Draft, argv) }
    end

    # Shared message-composition argv for both send and draft (everything bar
    # the body, which is piped on stdin, and the send-only `--send-now`).
    def compose_argv(args)
      argv = []
      argv.push("-f", args["from"].to_s)    if args["from"]
      argv.push("-t", args["to"].to_s)      if args["to"]
      argv.push("-c", args["cc"].to_s)      if args["cc"]
      argv.push("-b", args["bcc"].to_s)     if args["bcc"]
      argv.push("-s", args["subject"].to_s) if args["subject"]
      # Both values come from ANOTHER message, so both go through the shared
      # sanitizer — see Mailmate::HeaderValue for why this is not open-coded.
      argv.push("--header", "In-Reply-To: #{Mailmate::HeaderValue.bracket_message_id(args["in_reply_to"])}") if args["in_reply_to"]
      argv.push("--header", "References: #{Mailmate::HeaderValue.sanitize(args["references"])}")             if args["references"]
      # Parent-derived compose: hand the id to the CLI rather than deriving
      # here. `reply_to` is what a caller should reach for over hand-setting
      # in_reply_to/references — it builds the References chain from the
      # parent, the step that is easy to get subtly wrong and impossible to
      # notice afterwards (a mis-built chain sends fine and simply doesn't
      # thread).
      if (parent = args["reply_to"] || args["reply_all_to"] || args["forward"])
        flag = if args["forward"] then "--forward"
               elsif args["reply_all_to"] then "--reply-all-to"
               else "--reply-to"
               end
        argv.push(flag, parent.to_s)
        argv << "--no-quote" if args["quote"] == false
      end
      Array(args["attachments"]).each { |p| argv << p.to_s }
      argv
    end

    def call_open(args)
      argv = [args["id"].to_s]
      argv << "--print" if args["print_only"]
      run_cli(Mailmate::CLI::Open, argv)
    end

    def call_list_mailboxes(args)
      argv = []
      argv << "--no-count" if args.key?("count") && !args["count"]
      argv << "--csv"      if args["csv"]
      run_cli(Mailmate::CLI::Mailboxes, argv)
    end

    def call_list_tags(args)
      argv = []
      argv << "--defined" if args["defined"]
      run_cli(Mailmate::CLI::Tags, argv)
    end

    def call_resolve(args)
      eml_id = Mailmate::EmlLookup.resolve_id(args["id"].to_s)
      return text_error("Not found: #{args["id"].inspect}") if eml_id.nil? || eml_id.zero?

      path = Mailmate::EmlLookup.path_for(eml_id)
      return text_error("Not found: #{eml_id}.eml") unless path

      message_id = Mailmate::HeaderReader.message_id(path)
      mailbox    = path.sub("#{Mailmate.config.imap_root}/", "")
                       .sub(%r{/Messages/[^/]+\.eml\z}, "")

      payload = {
        eml_id:      eml_id,
        message_id:  message_id,
        message_url: message_id ? Mailmate::MidUrl.message_url_for(message_id) : nil,
        mid_url:     message_id ? Mailmate::MidUrl.for(message_id) : nil,
        path:        path,
        mailbox:     mailbox,
      }
      { content: [{ type: "text", text: JSON.pretty_generate(payload) }] }
    end

    # ---- protocol helpers -------------------------------------------------

    def run_cli(mod, argv)
      out, err, code = with_captured_io { mod.run(argv) }
      text = +""
      text << out unless out.empty?
      unless err.empty?
        text << "\n" unless text.empty?
        text << "[stderr]\n" << err
      end
      text = "(no output)" if text.empty?
      { content: [{ type: "text", text: text }], isError: code != 0 }
    end

    def with_captured_io
      old_out, old_err = $stdout, $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      code = yield
      [$stdout.string, $stderr.string, code.is_a?(Integer) ? code : 0]
    ensure
      $stdout = old_out
      $stderr = old_err
    end

    def with_stdin(text)
      old = $stdin
      $stdin = StringIO.new(text)
      yield
    ensure
      $stdin = old
    end

    def text_error(msg)
      { content: [{ type: "text", text: msg }], isError: true }
    end

    def jsonrpc_result(id, result)
      { jsonrpc: "2.0", id: id, result: result }
    end

    def jsonrpc_error(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end

    def write(stdout, obj)
      stdout.write(JSON.generate(obj) + "\n")
      stdout.flush
    end

  end
end
