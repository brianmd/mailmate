# Composing and threading

**This is the canonical description of how mailmate sends mail.** `mm-send`, `mm-draft`, the MCP `send` / `draft` tools, and every downstream consumer behave as described here. Other surfaces (the README, `--help` preambles, MCP tool descriptions) carry deliberately-minimal summaries and point here — they should never restate a rule in their own words, because a second independent statement of the same fact is what drifts.

## The two commands, and why there are exactly two

`mm-send` and `mm-draft` are thin wrappers around MailMate's bundled `emate mailto`, with `--markup markdown` enforced. The body is read from stdin; every other flag passes through to `emate`.

They differ on exactly one axis: **send-ability.** `mm-send` can send (with `--send-now`); `mm-draft` refuses `--send-now` with a nonzero exit and therefore *cannot*, no matter what flags it is handed. That refusal is the entire point — a "compose this but don't send it" instruction can't be silently defeated by a caller (human or model) adding a flag.

That axis, and only that axis, earns a command name. It has to be a name because a name is a guarantee you can reason about before running anything; a flag can be forgotten, mis-copied, or argued away. Every *other* variation — replying, replying-all, forwarding — is a flag, because none of them is safety-critical and because command names multiply where flags add. Cross-producting "threading mode" with "send-ability" would mean `mm-reply`, `mm-reply-all`, `mm-reply-draft`, `mm-reply-all-draft`, and then double again the day forwarding lands. The flag form covers the same matrix with two commands, permanently.

## Threading

**MailMate generates the outgoing `Message-ID` itself.** Never construct or pass one.

`In-Reply-To` and `References` are **pure pass-through**: whatever you set ships verbatim, and *what you don't set is absent*. This is the rule that surprises people, so state it plainly: **a `Re:` subject does not thread.** Modern mail clients thread on headers. A reply with a perfect `Re: …` subject and no threading headers appears in the recipient's client as a brand-new conversation, and nothing about the sender's own view reveals this — the failure is invisible from where you're standing.

The chain is built one way:

> `References` = the parent's own `References` header (if any) + the parent's `Message-ID` appended.
> If the parent is itself a thread root with no `References`, use its `Message-ID` alone.
> `In-Reply-To` = the parent's `Message-ID`.

Message-IDs may be written with or without angle brackets on input; they are normalized to the bracketed RFC 5322 form on the wire.

### Deriving it, rather than assembling it

Getting the chain wrong produces a message that looks correct everywhere you can see it and silently fails to thread. So prefer having it derived from the parent rather than assembling it by hand:

- **CLI:** `--reply-to <id>` / `--reply-all-to <id>` / `--forward <id>` on either command take the parent's eml-id or RFC Message-ID and derive the threading headers, recipients, and subject from it. `--no-quote` drops the quoted original.
- **MCP:** the `send` / `draft` tools take `reply_to` / `reply_all_to` / `forward` (plus `quote: false`), which hand the id to the same CLI. They also still accept `in_reply_to` / `references` directly — if you use those, set **both**.
- **Library:** `Mailmate::ReplyPrefill.build(id, mode:)` returns the derived fields without sending anything, and `mm-send --reply-to <id> --print-prefill` is the same thing as JSON for non-Ruby callers. That's the hook for a tool filling its own compose form.

Because `forward` derives no recipient, it is the one mode that still requires `to`.

Hand-assembly via `--header` remains available and is the escape hatch when the parent isn't in MailMate's index:

```sh
mm-send -f you@x -t them@y -s "Re: foo" \
  --header "In-Reply-To: <parent-message-id@domain>" \
  --header "References: <root-mid> <parent-mid>" \
  --send-now <<<"body"
```

### The merge rule

When a parent is supplied, **explicitly-passed fields always win; omitted fields follow normal reply rules** (parent's sender becomes the recipient, subject becomes `Re: <original>`, the quoted original seeds the body, reply-all additionally carries the other recipients minus your own identities).

This rule is uniform across every surface that composes from a parent — the CLI flags above and markdownr's compose popup — so a caller who learns it once can predict all of them. Overriding a visible field never drops the threading headers.

## Header safety

`--header` values ship verbatim into the message. Any value derived from *another message* is therefore untrusted input: a `Message-ID` or `References` carrying `\r\n` could otherwise smuggle additional RFC 5322 headers into the outgoing message. All header values are collapsed to a single line before injection. If you add a new path that pushes a `--header`, route it through the same sanitization rather than formatting the flag yourself.

## Identity

`-f <address>` picks which configured MailMate identity sends. Without it, MailMate uses its default identity — which, when the recipient is one of your own addresses, may not be the one you expect. Set it explicitly. `mmdiscover` lists the available addresses and writes them to `~/.config/mailmate/config.yml`, where `Mailmate::Identity` reads them.

## Prerequisites for markdown bodies

Bodies are markdown; MailMate renders them to HTML on the way out. For that to reach recipients, MailMate → Preferences → Composer must have **Preview: Display = Always** and **Replying/Forwarding HTML = Always embed**. These are global, one-time settings; without them recipients get plain text.

## Who points here

- `README.md` § `mm-send` / `mm-draft` — short usage orientation.
- `mm-send --help` / `mm-draft --help` preambles — the minimal operational recipe.
- The MCP server's `initialize` instructions and `send` / `draft` tool descriptions.
- markdownr's `.claude/instructions/nested/email.md` (compose popup + routes) and the private `email` skill (sender/signature doctrine). Those own their own layers — markdownr's UI surface and personal doctrine respectively — and defer to this file for anything below them.
