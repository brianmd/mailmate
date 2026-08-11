---
type: roadmap
outcome:
stage: idea
created_date: 2026-08-11
closed_date:
---

# Quicksearch parity with MailMate app

## Status: 🟡 in progress (phases 1–2 shipped 2026-08-11; phases 3–4 idea)

## Progress

| Phase | Scope | Status | Shipped |
|-------|-------|--------|---------|
| [[#Phase 1 — Date comparisons (`d <2026-08`, `d >2026-08`)|1]] | absolute date ranges | ✅ Done | 2026-08-11 |
| [[#Phase 2 — Boolean OR (and binds tighter, no parens)|2]] | `f bob s invoice or f ann s invoice` | ✅ Done | 2026-08-11 |
| [[#Phase 3 — Arbitrary header specs|3]] | `delivered-to:joe`, `x-mailer.name:mailmate` | 🕓 Pending | — |
| [[#Phase 4 — Message-state specs (unread, flagged, attachments)|4]] | quicksearch equivalents for `is:` / `has:` | 🕓 Pending | — |

## Context

The gem's `mmsearch` / MCP `search` implements a subset of MailMate's toolbar quicksearch: single-letter modifiers (`f t c s a b m d T`), AND-only combination, `!` negation on any operand, and dates as relative windows (`Nd/Nw/Nm/Ny` → `[today−N, ∞)`) or absolute points (`Y`, `Y-M`, `Y-M-D` → that day/month/year exactly). Parsing lives in `Mailmate::CLI::Search#parse_search` (`lib/mailmate/cli/search.rb`), date compilation in `compile_date_range`, evaluation in `matches?`.

While building the foreign-syntax translator (`SearchSyntax.translate`, shipped 2026-08-11), we catalogued what the MailMate app's search accepts that the gem does not. This doc is that catalog. The translator raised the stakes slightly: some foreign tokens (`before:X`, `older_than:N`) only became translatable because generic negation already covered them, and others (`is:unread`, `has:attachment`) remain untranslatable purely because the target syntax below doesn't exist yet — each phase here unlocks a corresponding translator upgrade.

> [!note] Two parity fixes shipped 2026-08-11 outside the phase list
> **`d 1d` off-by-one:** relative windows were `today − N` onward, so `d 1d` spanned two calendar days; the app's `d 1d` means today. Now `d Nd` = N calendar units *ending today* (`1d` = today, `2d` = yesterday + today), `d Nh` is the new rolling clock window (`d 24h` = last 24 hours), and `d 0d` is an error instead of a trap. **Display-zone day matching:** matching used the sender-local day sliced from the `#date` index while the output columns show the display-zone day, so `d 1d` returned mail displayed under yesterday's date whenever a sender's calendar ran ahead (UTC sender after 6pm MDT). Matching now converts through `Mailmate.localize` — the same conversion the date/time columns use — so the day a search matches is always the day the caller sees.

> [!note] Negation on dates already works — it was a documentation gap, not a code gap
> `matches?` applies the `!` negation flag uniformly across all spec types, including `:date`. So `d !3d` (received more than 3 days ago) has worked all along; it just wasn't documented. Fixed 2026-08-11 by adding it to the shared `SearchSyntax` rules/examples. It is what keeps `older_than:2w` → `d !2w` an exact translation, and it briefly carried `before:` (as `d !Nd`) until phase 1's comparisons gave that a readable form (`d <X`).

## Phase 1 — Date comparisons (`d <2026-08`, `d >2026-08`)

**Shipped 2026-08-11.** Comparison prefixes `>`, `>=`, `<`, `<=` on any date term: the prefix reshapes the period's inclusive `[lo, hi]` window (`>2026-08` → `[20260901, max]`, `<2026-08` → `[min, 20260731]` — `>`/`<` exclude the named period, `>=`/`<=` include it). Implemented in `compile_date_range` on the integer-range representation as predicted (near-free); `!` composes generically on top (`d !<X` = "not before X" — well-defined, so it was allowed rather than rejected).

Scope grew one item during review: **up-front date-spec validation** (`date_spec_error`). Multiple positive `d` specs AND together, so their windows must intersect; an empty intersection (`d >2026 d <2025`) or a single term that cannot match anything (`d >3d` — nothing is after a window that already reaches the future) is now a usage error (stderr + exit 2) instead of a silent 0-result success. The reduction-to-one-range idea that prompted this was assessed as not worth doing for *efficiency* (compiled ranges are memoized integer compares; the double check per message is noise) — the error message is the entire value, so only that shipped.

Translator upgrades landed in the same change: `before:X` → `d <X`, `until:X` → `d <=X`, `after:/since:X` → `d >=X` — readable in the announcement, month/year precision now allowed (`before:2026-05`), and future dates no longer refused. `older_than:`/`newer_than:` stay on relative windows (`d !2w` / `d 2d`).

## Phase 2 — Boolean OR (and binds tighter, no parens)

**Shipped 2026-08-11**, same day the decision was made (prompted by real queries — `d 1h or 2026-08-09` — hitting the AND-only engine and drawing spurious impossible-range errors). As decided: no expression tree, no parens. `or` is a top-level disjunction over AND-groups — `and` (juxtaposition) binds tighter — with `(f bob or f ann) s invoice` written out as `f bob s invoice or f ann s invoice`. `parse_search` now returns a list of groups (tokenizer keeps quoted-ness so `s "or"` stays a literal term), `matches?` is any-group-matches with `order_specs`' cost-ranked short-circuiting intact per group.

The modifier-distribution question resolved toward the app's shorthand: a group that **opens with a bare unquoted term inherits the modifier in force** at the end of the previous group, so `d 2024 or 2025 or 2y` and `d 1h or 2026-08-09` work; a quoted opener (`d 2024 or "2025"`) stays a literal Common-specifier term.

`date_spec_error` went per-group: every branch dead → usage error (exit 2) as before; one dead branch among live ones → a `dead or-branch (matches nothing): …` stderr warning while the live branches run.

## Phase 3 — Arbitrary header specs

The app can search any header by name, including structured sub-paths: `delivered-to:joe`, `x-mailer.name:mailmate`. The gem has only the fixed modifier set.

If pursued, two open questions before code:

1. **Syntax collision with the foreign-token translator.** `delivered-to:joe` is exactly the `key:value` shape that `SearchSyntax.translate` inspects and `zero_result_hint` flags. Rule needs deciding up front — e.g. known foreign keys keep translating, anything else with a `:` becomes a real header spec (which would *retire* the "searched as literal text" trap wholesale — likely the right end state, and worth calling out as the phase's real payoff).
2. **Index coverage.** Fixed modifiers ride MailMate's per-header indexes (`#from#lc` etc.). Arbitrary headers may have no index, forcing `Mail.read` per candidate — fine as a correctness fallback, but the cost cliff should be visible (a note in `--help`, or a spec-cost tier that evaluates these last, as body matching does today).

Verify the app's actual sub-path vocabulary (`.name`, `.address`, others?) against MailMate's manual/behavior before implementing.

## Phase 4 — Message-state specs (unread, flagged, attachments)

Not in the user-reported gap list, but it is the remaining untranslatable-foreign-key family: `is:unread`, `is:flagged`, `has:attachment` have no quicksearch target. The gem already reads flag state (the `flags` output column comes from the `#flags` index), so the data exists; only search-side syntax is missing. The app's quicksearch state vocabulary should be checked first so we adopt its spelling rather than inventing one.

## Recommendation

Phase 1 first — smallest change, immediately improves translator output readability, and its inclusivity decision is prerequisite thinking for Phase 2. *(Both done 2026-08-11.)* Phase 3 is the largest payoff (it dissolves the literal-text trap entirely) but has the widest blast radius through the translator contract; do it next while the range semantics are fresh. Phase 4 can wait for demand.
