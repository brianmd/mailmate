# mailmate

Ruby toolkit for [MailMate](https://freron.com) on macOS — a smart-mailbox filter engine, on-disk index readers, and CLI tools (`mmsearch`, `mmmessage`, `mmopen`, `mm-mailboxes`, `mmtags`, `mm-modify`, `mm-verify`, `mm-send`, `mm-draft`, `mmdiscover`) for searching, reading, modifying, and sending mail.

**Requires macOS with MailMate installed.** The library code (filter parser, evaluator) works anywhere, but the integration with MailMate itself — AppleScript, on-disk index reads, the `emate` binary — is macOS-only by way of MailMate being macOS-only.

## Privacy Policy

This gem — including its MCP server — contains **no networking code at all**.
It never opens a network connection of any kind, for any purpose: no HTTP, no
sockets, no telemetry endpoints. You can verify this from the source — there
isn't a single `net/*`, `open-uri`, or socket require anywhere in `lib/` or
`exe/`. The only network activity in the project's entire lifecycle happens at
install time: `gem install` fetches from rubygems.org, and `install.sh` may
additionally fetch a relocatable Ruby from GitHub. After that, nothing.

- **Data collection:** none. No telemetry, analytics, usage data, or crash
  reports — and no code capable of transmitting them.
- **Usage and storage:** the gem reads MailMate's existing on-disk mail store
  (`~/Library/Application Support/MailMate`) and drives the MailMate app via
  AppleScript. It creates no data stores of its own beyond files you
  explicitly ask it to write. The only optional configuration file is
  `~/.config/mailmate/config.yml`, which you author yourself.
- **Third-party sharing:** none by the gem itself — it has no means to share
  anything. Two things *adjacent* to it can move data off your machine, and
  both are under your control: (1) `mm-send` / the `send` tool hands the
  message to the MailMate app, and **MailMate** performs the delivery to the
  recipients you named — the gem transmits nothing; (2) when the MCP server
  is used from an AI client (Claude Desktop, Claude Code, etc.), message
  content returned by its tools enters that client's conversation and is
  transmitted to that AI provider under *its* privacy policy — choose which
  messages you surface accordingly.
- **Data retention:** none. The gem retains nothing between invocations;
  your mail stays wherever MailMate keeps it.
- **Contact:** brian@murphydye.com, or open an issue at
  <https://github.com/brianmd/mailmate/issues>.

## Install

Pick the path that matches how you'll use it:

- **Claude Code plugin** — MCP tools for Claude, zero manual setup (below)
- **One-line installer** — the MCP server for any MCP client, fully isolated under `~/.mailmate-mcp`
- **`gem install mailmate`** — the CLI tools (and MCP server) on your own Ruby

### Requirements

- **macOS** with **MailMate** installed (and running, for any command that drives the UI or sends mail).
- **Ruby ≥ 3.0** — for the plugin and one-line installer this is optional: if no suitable Ruby is found, they download a private relocatable Ruby into `~/.mailmate-mcp/ruby` and never touch your system.
- No third-party CLI tools — the gem only shells out to macOS-bundled `plutil`, `osascript`, and `open`, plus MailMate's bundled `emate`.

### Claude Code plugin

This repo doubles as a Claude Code plugin marketplace. Inside Claude Code:

```
/plugin marketplace add brianmd/mailmate
/plugin install mailmate@brianmd
```

The plugin's MCP server self-provisions on first launch — Ruby (if needed) and gem dependencies go into `~/.mailmate-mcp`; nothing touches your system Ruby, Homebrew, or shell profile. It runs the plugin's bundled source, so plugin updates take effect without waiting for a gem release. Uninstall: `/plugin uninstall mailmate`, then `rm -rf ~/.mailmate-mcp`.

### Claude Cowork (desktop app)

The same plugin works in Cowork on the macOS desktop app — verified end to end, including a from-scratch first run:

1. In Cowork: **Customize → Plugins → + → Add marketplace** → `brianmd/mailmate`, then install **mailmate** from the Discover tab.
2. Ask Claude about your mail. The first launch provisions the runtime inside Cowork's sandbox, which can take a minute or two, and Cowork will ask you to **allow the connector's commands and file access** — those approvals are the gate to your local mail store.
3. The Claude desktop app must be running on the Mac where MailMate lives; `send`, `draft`, `modify`, and `open` additionally need the MailMate app running (as always).

Cowork runs the connector through the desktop app's sandboxed bridge, so its provisioning leaves nothing on your real filesystem — not even `~/.mailmate-mcp` (only the Claude Code path creates that directory).

### One-line installer (any MCP client)

```bash
curl -fsSL https://raw.githubusercontent.com/brianmd/mailmate/main/install.sh | bash
```

Installs the released gem into an isolated `GEM_HOME` under `~/.mailmate-mcp` (provisioning a private Ruby only if none ≥ 3.0 is found), writes a launcher shim, and registers it with Claude Code when the `claude` CLI is present (pass `--no-register` to skip). For Claude Desktop, add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "mailmate": { "command": "/Users/<you>/.mailmate-mcp/bin/mailmate-mcp" }
  }
}
```

`~/.mailmate-mcp` is the entire footprint. Uninstall: `bash install.sh --uninstall` (or just delete the directory), plus `claude mcp remove mailmate`.

### As a Ruby gem (CLI tools)

```bash
gem install mailmate
```

Then optionally bootstrap your config (will happen automatically on first invocation of any command from an interactive shell if it hasn't been run before):

```bash
mmdiscover
```

`mmdiscover` reads MailMate's `Sources.plist` and `Identities.plist`, shows you the accounts and addresses it found, and offers to write `~/.config/mailmate/config.yml` from them. It also writes `~/.config/mailmate/bundle_loader.rb` for MailMate bundles. Running it explicitly is only needed in non-TTY contexts (cron jobs, MCP servers) — there, the gem falls back to built-in defaults and warns once.

### Optional: `mmmessage --markdown`

**On the vast majority of Ruby setups (stock `arm64-darwin` or `x86_64-darwin` Ruby) this step is a no-op — nokogiri ships a precompiled binary, you can skip the rest of this section and move on.** Keep reading only if your `gem install` actually fails.

`mmmessage --markdown` renders HTML-only message bodies as readable markdown. It needs the `reverse_markdown` gem, which has `nokogiri` as a transitive dependency:

```bash
gem install reverse_markdown
```

That single command pulls `nokogiri` in automatically — no separate `gem install nokogiri` step. This is kept out of the base install because nokogiri ships a native extension. On Ruby/platform combinations without a precompiled match nokogiri falls back to compiling from source — it vendors its own libxml2/libxslt, but it does need a C compiler, which on macOS means Xcode Command Line Tools (`xcode-select --install`). If `gem install reverse_markdown` fails, that's almost certainly the cause.

If you never use `--markdown`, you never pay any of this. If you do invoke `--markdown` without the gem installed, `mmmessage` warns with a clear install hint and falls back to the raw HTML body (it does not abort — so the in-process MCP server survives a missing optional dependency). The plugin launcher and one-line installer attempt this gem automatically and degrade the same way if it fails to build.

### From source (development)

If you're hacking on the gem itself, skip `gem install` and put the repo's `exe/` on your `PATH`. Clone wherever you keep source repos, then prepend its `exe/` to `PATH` from your shell's rc file (`~/.zshrc`, `~/.bashrc`, etc.):

```bash
git clone https://github.com/brianmd/mailmate.git
cd mailmate

# In your shell rc file, add (adjust the path to wherever you cloned):
#   export PATH="/absolute/path/to/mailmate/exe:$PATH"
# Then reload the shell (open a new tab, or `source` the rc file).
```

Then `mmdiscover` as above.

### MCP server (manual setup)

The gem ships an MCP server (`exe/mailmate-mcp`) that exposes the same surface to AI assistants as JSON-RPC tools: `search`, `message`, `modify`, `verify`, `send`, `draft`, `open`, `list_mailboxes`, `list_tags`, `resolve_id`. Every tool carries MCP annotations (`readOnlyHint`/`destructiveHint`) so clients can apply sensible permission behavior. If you installed via the plugin or one-line installer above, this is already wired up; after a plain `gem install mailmate`, register it yourself:

```bash
claude mcp add --scope user mailmate "$(which mailmate-mcp)"
```

Or add manually to `~/.claude.json` under `"mcpServers"`:

```json
"mailmate": {
  "type": "stdio",
  "command": "/absolute/path/to/mailmate-mcp",
  "args": [],
  "env": {}
}
```

For Claude Desktop, use the same command path in `claude_desktop_config.json` as shown under the one-line installer. Restart Claude Desktop after any change to server code or config.

## Example usage

### `mmsearch` — find messages

```bash
# Default: today's mail, all mailboxes
mmsearch

# From "Substack" in the last 7 days
mmsearch 'f substack d 7d'

# Subject contains "invoice due", not the word "draft"
mmsearch 's "invoice due" !draft'

# Received in May 2026
mmsearch 'd 2026-05'

# Custom columns + cap results + raw CSV (no padding)
mmsearch 'f acme' 'id flags subject from' --limit 20 --no-align
```

**Quicksearch syntax.** The search-string is a list of specs combined with **AND**; a bare `or` separates alternatives, and AND binds tighter (no parens — write `(f bob or f ann) s invoice` out as `f bob s invoice or f ann s invoice`). After `or`, a bare first term inherits the modifier in force: `d 2024 or 2025 or 2y`. Wrap multi-word terms in `"double quotes"` (also how to search for the literal word "or"). `mmsearch --help` is the canonical, always-current rendering of this table.

| Modifier | Scope |
|---|---|
| _bare term_ | From/To/Cc/Subject **or body** contains (the UI quicksearch default). `--headers-only` skips the body scan. |
| `f <term>` | From contains. |
| `t <term>` | To/Cc (recipients) contains. |
| `c <term>` | Cc contains. |
| `s <term>` | Subject contains. |
| `a <term>` | Any address header contains. |
| `b <term>` | Body (plain text) contains. |
| `m <term>` | Common headers OR body. |
| `d <date>` | Received: `Nh` (rolling clock hours, `24h` = last 24 hours), `Nd`/`Nw`/`Nm`/`Ny` (N calendar units ending today — `1d` = today, `2d` = yesterday + today), or absolute `Y`, `Y-M`, `Y-M-D`. Slash dates are month-first American (`8/9/2026` = Aug 9); `--european` flips to day-first. Comparisons on absolute dates: `d >2026-08` (after), `d <2026-08` (before), also `>=`/`<=`. |
| `T <tag>` | Tags / IMAP keywords (`K` is a synonym). |
| `is:<state>` | Message state: `is:unread`, `is:read`, `is:flagged`, `is:replied`, `is:draft` (Gmail synonyms `starred`/`answered` work; `-is:unread` negates). |
| `has:attachment` | Root MIME type is `multipart/mixed` — the standard attachment layout. |
| `!<value>` | Negate, e.g. `f !smith` = From does NOT contain smith; works on dates too (`d !3d` = more than 3 days ago). |

Dates match on the **display-zone day** — the same day the `date`/`time` output columns show. An impossible date term or combination (`d 2026-02-31`, `d >2026 d <2025`) is a usage error, not a silent empty result. Familiar foreign `key:value` tokens (`from:bob`, `date:today`, `after:2026-08-01`, `older_than:2w`) are auto-translated to quicksearch with each rewrite announced on stderr; unrecognized keys (`is:unread`) are searched as literal text, and an empty result says so.

The `--mailbox` argument accepts an account, an `account/path`, a bare mailbox name matched across accounts, or a **smart-mailbox name** (e.g. `Newsletters`, `Receipts`, `Priority`) whose filter is ANDed into the search.

**Output fields.** Default columns are `flags date time direction party subject`. Prefix a field list with `+` to add to the defaults; a bare list replaces them (`id` is always the first column).

| Field | What it shows |
|---|---|
| `id` | The `.eml` body-part ID (always emitted first). |
| `path` | Absolute file path. |
| `mailbox` | `<account>/<mailbox>` relative to the IMAP root. |
| `from`, `to`, `cc`, `bcc`, `reply-to` | Address headers (joined with `; `). |
| `subject` | Decoded subject. |
| `date` / `time` | `YYYY-MM-DD` / `HH:MM` (sender's timezone). |
| `message-id` | The `Message-ID` header. |
| `direction` | `→` outbound, `←` inbound (rendered as `dir`). |
| `party` | The other party — recipient(s) if outbound, sender if inbound. |
| `flags` | Two chars: position 1 archive-state (`A` archived / `P` primary), position 2 read-state (`R` read / `U` unread) — e.g. `AR`, `PU`. |
| `read` / `archive` | Standalone versions of the two `flags` positions. |

### `mmmessage` — read one message

```bash
# By local eml-id (the integer Msg ID column in MailMate)
mmmessage 183715

# By portable Message-ID (quote it — the angle brackets are shell metacharacters)
mmmessage '<CA+abc123@mail.example.com>'

# Raw .eml bytes (e.g. to pipe into `mail` parsers)
mmmessage 183715 --raw

# Body only, no headers block
mmmessage 183715 --text-only

# Open in MailMate's UI instead of printing (delegates to mmopen)
mmmessage 183715 --mailmate

# Render an HTML-only message as clean markdown (no-op for text/plain bodies)
mmmessage 183715 --markdown
```

`--markdown` uses `reverse_markdown` + Nokogiri preprocessing to drop `<style>`/`<script>` blocks and strip newsletter preview-text padding (zero-width chars, runs of non-breaking / figure / narrow spaces, etc.). Conversion quality is good for plain replies/threads and rough for marketing-newsletter HTML (which uses nested layout tables); the raw source is still available with `--raw`.

### `mmopen` — open a message in MailMate's UI

```bash
# By eml-id, Message-ID, message:// URL, or mid: URL — all six input forms
# that EmlLookup.resolve_id understands.
mmopen 183715
mmopen '<abc@example.com>'
mmopen 'message://%3Cabc%40example.com%3E'

# Print the mid: URL instead of opening it (useful in pipelines)
mmopen 183715 --print

# Spawn the viewer in the background — MailMate stays where it is and
# your keyboard focus is not stolen. Useful when scripting / cross-app.
mmopen 183715 --background    # also: -g
```

### `mm-mailboxes` — list accounts and mailboxes

```bash
# Grouped by account, with .eml counts per IMAP mailbox + smart-mailbox names
mm-mailboxes

# Skip counts (much faster on large stores)
mm-mailboxes --no-count

# Flat CSV (one row per mailbox; account repeated in column 1)
mm-mailboxes --csv
```

Account names are URL-decoded for display (`%40` → `@`). Smart-mailbox names appear in their own section with `-` for count (not calculated — would require evaluating each filter).

### `mmtags` — list tags

```bash
# Tags actually applied to messages, sorted by usage count
mmtags

# Tags defined in MailMate → Preferences → Tags (may include unused ones)
mmtags --defined
```

The default reads MailMate's `#flags` index (IMAP keywords, system flags excluded). The two views can differ: tags can be applied programmatically (via IMAP keyword) without being registered in Preferences, and tags can be defined in Preferences without being applied to any message yet.

### `mm-modify` — change message state

```bash
# Mark a message read, flag it, and archive it — one open/wait cycle
mm-modify 183715 read flag archive

# Add a tag
mm-modify 183715 tag urgent

# Pure-move (one or more moves, nothing else): same-account moves take a
# fast path — direct .eml rename on disk, no UI, no focus theft.
mm-modify 183715 move Archive

# Chain with other actions: everything (including the move) goes through
# MailMate's UI in user-supplied order. We're already paying for the UI for
# the tag/read; letting MailMate do the move too keeps its state in sync
# with itself, no #source-index staleness window.
mm-modify 183715 tag processed read move Archive

# Dry-run first
mm-modify 183715 archive --dry-run

# Print the current flags after acting (raw probe)
mm-modify 183715 read --verify

# As of 1.2.0, `--verify` works in `--dry-run` mode too — pair them as a
# post-hoc state probe (run the action first, then re-run with --dry-run
# --verify to confirm the change took effect).
mm-modify 183715 read --dry-run --verify

# Effect verification (--check): confirm the action actually landed on THIS
# eml-id by re-reading its #flags index. This is the only way to catch a
# Message-ID that resolved to a different duplicate copy — AppleScript can't
# report which message it acted on, but the index can show whether OURS
# changed. A mismatch exits 3. Opt-in because MailMate flushes #flags ~5s
# after acting, so --check polls up to --check-timeout (default 8s).
mm-modify 183715 tag urgent --check
```

**Tip — batch your actions.** Doing all related changes in **one** `mm-modify` invocation is still worthwhile: one open/close cycle instead of two, and the chain runs deterministically without you having to think about ordering. Splitting is safe — `path_for` falls back to a filesystem glob if MailMate's `#source` index is briefly stale after a fast-move — just slower than batching.

### `mm-verify` — confirm a batch of modifies with ONE flush-wait

Inline `--check` pays MailMate's ~5 s `#flags`-flush latency *per message* — verifying 50 modifies that way would cost ~250 s. But `#flags` is a single global file flushed once, so a whole batch can be confirmed by waiting for that flush **once**. `mm-modify --emit-check` performs the action and prints a JSON *check-ticket* instead of waiting; collect the tickets, then hand them to `mm-verify`.

```bash
# Action phase: act on N messages, no per-message wait. Each --emit-check
# prints a one-line ticket {eml_id, message_id, expectations} to stdout.
for id in 183715 183720 183733; do
  mm-modify "$id" tag triaged --emit-check >> tickets.jsonl
done

# Verify phase: confirm the whole batch in one index-flush wait.
mm-verify --file tickets.jsonl
# → JSON {checked, passed, failed, waited_seconds, results:[{eml_id, ok, flags, unmet}]}
#   exit 0 if all confirmed, 3 if any failed.

# Tickets can also be piped, or passed as a JSON-array argument:
mm-modify 183715 flag --emit-check | mm-verify
```

A failed ticket means that action didn't land on that eml-id — it registered on a different duplicate copy, or not at all. Chains containing `move`/`archive`/`delete` aren't flag-verifiable and carry empty expectations (auto-pass).

### `mm-send` — send mail

`mm-send` is a thin wrapper around MailMate's bundled `emate mailto`, with `--markup markdown` enforced. The body is read from stdin.

```bash
# One-liner
echo "Quick **markdown** body." | mm-send -t friend@example.com -s "Hello"

# Heredoc with cc + send-now
mm-send -t friend@example.com -c cc@example.com -s "Status update" --send-now <<'EOF'
## Update

- shipped the thing
- on to the next
EOF

# Attach files (positional args after options)
mm-send -t friend@example.com -s "Photos" /path/to/photo1.jpg /path/to/photo2.jpg <<<"See attached."
```

#### Replies and threading

MailMate auto-generates the outgoing `Message-ID` for every send — never the caller's job. `In-Reply-To` and `References` are pure pass-through: whatever you set via `--header` ships verbatim, and **what you don't set is absent**. A reply with a `Re: …` subject but no threading headers shows up as a brand-new conversation in modern mail clients (they thread on headers, not subjects).

To make a reply land in-thread, pass both headers:

```bash
mm-send -f you@x -t them@y -s "Re: foo" \
  --header "In-Reply-To: <parent-message-id@domain>" \
  --header "References: <root-mid> <parent-mid>" \
  --send-now <<<"body"
```

Construct `References` as the source message's `References` header (if any) with the source's `Message-ID` appended. If the source is itself a thread root with no `References`, just use its `Message-ID` alone.

The same passthrough applies to the `mailmate-mcp` `send` tool — see the `from`, `in_reply_to`, and `references` fields.

### `mm-draft` — compose without sending

`mm-draft` is identical to `mm-send` in every way except one: it **never sends**. It refuses the `--send-now` flag with a nonzero exit, so a "compose this but don't send it" instruction can't be silently defeated by passing the flag that flips `emate mailto` from draft-pause to send. Without `--send-now` the two commands already behave identically (open a draft window in MailMate and wait) — `mm-draft` just removes the ability to send at all.

```bash
# Opens a draft in MailMate; never sends.
echo "Quick **markdown** body." | mm-draft -t friend@example.com -s "Hello"

# Threading headers and attachments work exactly as in mm-send.
mm-draft -f you@x -t them@y -s "Re: foo" \
  --header "In-Reply-To: <parent-message-id@domain>" \
  --header "References: <root-mid> <parent-mid>" <<<"body"

# Passing --send-now is refused (exit 2):
mm-draft -t friend@example.com -s "nope" --send-now <<<"body"
# → mm-draft: refusing --send-now — mm-draft only ever creates drafts. Use mm-send to send.
```

Reach for `mm-draft` (or the `mailmate-mcp` `draft` tool) whenever the instruction is "write/compose but don't send" — it's the unambiguous, can't-misfire choice. The `draft` MCP tool mirrors `send` minus the `send_now` field.

### Why the names

The `mm` prefix is for tab completion: typing `mm<tab>` in a shell lists every command in the toolkit. The dash matters:

- **`mm<name>`** (no dash) — **read** operations. `mmsearch`, `mmmessage`, `mmopen`, `mmtags`, `mmdiscover` observe MailMate's on-disk state without changing it. (`mmopen` activates MailMate's UI but doesn't modify any message.)
- **`mm-<name>`** (with dash) — **write** operations. `mm-modify`, `mm-send`, `mm-draft` change state (or compose/send mail). `mm-mailboxes` is an exception: read-only, but uses the dash to keep `mmm<tab>` free for the daily-driver `mmmessage`. Typing `mm-<tab>` filters to the write-leaning commands. (`mm-draft` only ever opens a draft — it never sends.)

## Limitations

A few rough edges to be aware of:

1. **Non-move `mm-modify` actions briefly spawn a MailMate viewer window.** Same-account `move` actions use a fast path — a direct `.eml` rename on disk — so they're entirely silent. Everything else (`read`, `flag`, `tag`, `archive`, `junk`, `delete`, etc.) drives MailMate's URL handler: each invocation opens a message-viewer window via the `mid:` URL in the background, runs AppleScript key-binding selectors against it, then closes the window.

   **As of 1.2.0 this runs in the background.** MailMate is not brought to the foreground, your keyboard focus stays in whatever app you were using, and you can keep working — even during bulk loops. The viewer windows still appear briefly in MailMate's own window list before closing, but they don't take over your screen. The previous behavior (full-screen takeover, close-keystroke landing on the wrong window) is gone.

   Two residual caveats:
   - **Don't bring MailMate to the foreground during a run.** If you click into MailMate or Cmd-Tab to it while `mm-modify` is mid-flight, MailMate's responder chain shifts and subsequent perform-selectors may misbehave. Wait for the run to finish.
   - **MailMate must be running.** See #3.

   The `--keep-window` flag leaves the spawned viewers open if you want to inspect them. Batch multiple actions into one `mm-modify` invocation when you can — they share a single open/close cycle (or skip it entirely for pure-move).

2. **`eml-id` is machine-local; prefer `Message-ID:`.** The integer eml-id (also shown as MailMate's "Msg ID" column) is just the filename of the `.eml` on disk and differs on every install — copy/pasting an eml-id from your desktop to your laptop will refer to a different message (or none at all). For anything you want to keep, store the RFC `Message-ID:` header (which `mmmessage` prints) and pass that to the CLIs. The `mid:%3C<message-id>%3E` URL scheme works portably for the same reason.

3. **MailMate must be running.** Anything that goes through `mm-modify` requires MailMate open and unblocked by modal dialogs. `mm-send` likewise needs MailMate running — `emate mailto` opens a draft window in the running MailMate process, so without MailMate up there's nowhere for the draft to land (this is true with or without `--send-now`). Headless / unattended use isn't supported.

4. **Single-account `mm-send` defaults.** `mm-send` passes flags straight through to `emate mailto`. If you have multiple identities configured in MailMate and don't pass `-f`, MailMate picks the default identity — there's no opinionated multi-account routing in the wrapper.

## Status

1.8.0 — Message-state specs. `is:unread`, `is:read`, `is:flagged`, `is:replied`, `is:draft`, and `has:attachment` are first-class quicksearch (the MailMate app has no state vocabulary in its toolbar search — its `A` modifier searches attachment *filenames* — so the familiar Gmail spellings were adopted, including the `starred`/`answered` synonyms and `-is:unread` negation). Flag states read the `#flags` index; attachment presence reads the indexed root `content-type` (`multipart/mixed`). An unknown state value (`is:snoozed`) is a usage error naming the known states, not a silent empty result.

1.7.0 — Search-language release, driven by a study of how LLM agents actually misuse `mmsearch`. The quicksearch syntax reference is now single-sourced (`Mailmate::SearchSyntax`) into both `mmsearch --help` and the MCP `search` description, so the two can no longer drift. Foreign `key:value` dialects (Gmail/Outlook/Spotlight — `from:bob`, `date:today`, `after:2026-08-01`, `older_than:2w`) auto-translate to their exact quicksearch equivalent, loudly: each rewrite is announced on stderr, and untranslatable keys are flagged when a search returns nothing. The language itself grew: boolean `or` (AND binds tighter, no parens; a bare term after `or` inherits the modifier in force), date comparisons (`d >2026-08`, `d <2026-08`, `>=`/`<=`), rolling hour windows (`d 24h`), and American slash dates (`d 8/9/2026`; `--european` for day-first). Two semantic fixes: `d 1d` now means *today* (N calendar units ending today, matching the MailMate app; the old today−N made it span two days), and date matching converts to the display zone — the same conversion the `date`/`time` columns use — so the day a search matches is always the day shown (sender-local index days previously leaked "tomorrow's" mail into `d 1d`). Impossible date terms and combinations (`d 0d`, `d 2026-02-31`, `d >2026 d <2025`) are usage errors instead of silent empty results.

1.6.0 — Distribution release. The repo is now a Claude Code plugin marketplace (`/plugin marketplace add brianmd/mailmate`), and a one-line `install.sh` provisions the MCP server into an isolated `~/.mailmate-mcp` — including a private relocatable Ruby when no Ruby ≥ 3.0 is present — without touching system Ruby, Homebrew, or shell profiles. Every MCP tool now carries a `title` plus `readOnlyHint`/`destructiveHint` annotations (Claude clients use these for permission behavior; Anthropic's directory review requires them), and the README gains a formal Privacy Policy section. No changes to CLI or library behavior.

1.5.0 — Reliability and batch-verification for `mm-modify`, plus search/read speedups. `mm-modify` gains a no-window retry guard (a `mid:` open that spawns no viewer would otherwise act on the wrong message) and opt-in effect verification: `--check` confirms a flag/tag/read action landed on the target eml-id by re-reading `#flags` (the only way to catch a duplicate-Message-ID misland). Because MailMate flushes `#flags` to disk ~5 s after acting, a new **`mm-verify`** command plus `mm-modify --emit-check` decouple acting from confirming — collect JSON check-tickets across a batch and verify them all in one flush-wait instead of paying the latency per message. `mmsearch` is substantially faster (compiled date ranges, cheapest-spec-first ordering, bulk-unpack index reader, inverted body search) with bit-identical output; the persistent MCP server now invalidates index caches on disk change. `mmmessage` shows user tags and lazy-loads the `mail` gem (`--raw`/`--mailmate` skip it). MCP: `message` gains `markdown`, `modify` gains a `check` mode (`none｜inline｜defer`), and a new `verify` tool batch-confirms deferred tickets.

1.2.0 — `mm-modify` no longer brings MailMate to the foreground and is roughly 8× faster on single-action invocations. Internally: the open call uses `open -g -a MailMate <url>` to keep MailMate in the background, and the fixed `--settle` sleeps are replaced by active waits (polling for the spawned viewer window to appear). `mmopen` gains a `--background` / `-g` flag for ad-hoc use. `mm-modify --verify` now works in `--dry-run` mode as a post-hoc state probe. `--settle` is preserved for backward compat; it now caps the active-wait timeout rather than fixing sleep duration.

1.1.0 — `reverse_markdown` (and its transitive `nokogiri` dep) is now opt-in rather than auto-installed. Run `gem install reverse_markdown` if you want `mmmessage --markdown`; everything else is unchanged.

1.0.0 — initial public release; API stable from this point. Breaking changes bump the major version going forward.

## Commands

| Command | What it does |
|---|---|
| `mmsearch` | List messages matching a quicksearch expression. Output is aligned CSV. |
| `mmmessage` | Print one message by id (decoded headers + plain-text body). `--mailmate` opens in MailMate instead; `--markdown` renders HTML-only bodies as clean markdown. |
| `mmopen` | Open one message in MailMate's UI (via `open mid:…`). `--print` returns the URL. |
| `mm-mailboxes` | List accounts, IMAP mailboxes (with optional counts), and smart-mailbox names. |
| `mmtags` | List user tags applied to messages (with counts) or defined in Preferences. |
| `mm-modify` | Mark read/flag/tag/archive a message via AppleScript; same-account `move` uses a fast `.eml`-rename path with no UI takeover. `--check` confirms the change landed; `--emit-check` defers confirmation to `mm-verify`. |
| `mm-verify` | Batch-confirm `mm-modify --emit-check` tickets against the `#flags` index in one flush-wait. JSON in, JSON summary out. |
| `mm-send` | Send mail through `emate` with a markdown body on stdin. |
| `mm-draft` | Like `mm-send`, but only ever opens a draft — refuses `--send-now` (exit 2). |
| `mmdiscover` | First-run bootstrap; (re-)writes the user config from MailMate's plists. |

Each command takes `--help` for usage. Tab-completion: `mm<tab>` lists every command; `mms<tab>` → `mmsearch`; `mmm<tab>` → `mmmessage`; `mm-<tab>` lists the write-side commands.

## eml-id vs Message-ID

The CLI tools take an `eml-id` — the integer filename of MailMate's `.eml` storage (the same value as the **Msg ID** column in MailMate's UI, internally MailMate's `#body-part-id`). It's a counter MailMate maintains locally; **eml-ids are NOT portable across machines.** The same RFC `Message-ID:` will have a different eml-id on every install. If you need a cross-machine reference, use the message's `Message-ID:` header (which `mmmessage <id>` prints). The `mid:%3C<message-id>%3E` URL scheme works portably for the same reason.

## Library

```ruby
require "mailmate"

# Parse and evaluate a MailMate smart-mailbox filter
ast = Mailmate.compile_filter("from.name = 'Substack' and #date-received > '1 days ago'")
# ... feed `ast` to Mailmate::Evaluator ...

# Read the binary `#flags` index
reader = Mailmate::IndexReader.for("#flags")
reader.flags_for(180644) # → ["\\Seen", "$Forwarded"]

# Configuration
Mailmate.config.app_support_dir # → expanded path
Mailmate::Identity.mine?("brian@example.com") # → true if in identities
```

## Using from a MailMate bundle

`mmdiscover` writes `~/.config/mailmate/bundle_loader.rb` — a one-line bootstrap that lets MailMate bundle handlers find the gem. Every handler then does:

```ruby
#!/usr/bin/env ruby
load File.expand_path("~/.config/mailmate/bundle_loader.rb")
require "mailmate"

# ... use Mailmate::IndexReader, Mailmate::HeaderReader, Mailmate::Identity, etc.
```

The bootstrap file is the only place that knows the gem's path on disk, so individual bundles stay portable across machines — copy a `.mmBundle/` to another Mac, run `mmdiscover` there, and the bundle works.

### Sample bundle

The gem ships a working sample at `~/Library/Application Support/MailMate/Bundles/Mailmate.mmBundle/`:

- **`Commands/Inbox Note.mmCommand`** — declares input (canonical body), env vars (from / subject / date / message-id), and output type (actions JSON).
- **`Support/bin/inbox_note.rb`** — the handler. Reads body from stdin, headers from env, uses `Mailmate::Identity.mine?` to decide inbound/outbound, writes a markdown note to `~/code/claude/people/projects/email/inbox/<YYYY>/<MM>/`, and returns `moveMessage` (archive) + `notify` actions.

To enable: restart MailMate (or use "Reload Bundles" in the Command menu). The "→ Inbox Note" entry will appear in `Command → Mailmate gem bundle`. Override the output directory by setting `MAILMATE_INBOX_DIR` in the `.mmCommand`'s `environment` block.

See `~/code/claude/people/projects/email/mailmate-bundles.md` for the bundle plist mechanics in full.

## Configuration

Loading order: built-in defaults → `~/.config/mailmate/config.yml` → environment variables (override YAML).

Available settings:

| Key (YAML) | Env var | Default |
|---|---|---|
| `app_support_dir` | `MAILMATE_APP_SUPPORT_DIR` | `~/Library/Application Support/MailMate` |
| `identities` (array) | `MAILMATE_IDENTITIES` (comma-separated) | `[]` |

A sample `config.yml.example` ships in the repo with placeholder values.

## Tests

Two suites:

```bash
rake test         # hermetic — no MailMate required, runs anywhere
rake test:live    # live — runs against your actual MailMate install
```

`rake test:live` smoke-tests every smart mailbox in your `Mailboxes.plist`, decodes every `Database.noindex/Headers/*` index, and verifies one message round-trips through `EmlLookup` → `HeaderReader` → `MidUrl`. It's user-runnable so you can verify the gem works on your machine.

## License

MIT. See `LICENSE.txt`.
