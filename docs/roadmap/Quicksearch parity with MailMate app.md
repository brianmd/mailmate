---
type: roadmap
outcome:
stage: idea
created_date: 2026-08-11
closed_date:
---

# Quicksearch parity with MailMate app

## Status: 🔵 idea (gaps catalogued while building the foreign-syntax translator; none blocking)

## Progress

| Phase | Scope | Status | Shipped |
|-------|-------|--------|---------|
| [[#Phase 1 — Date comparisons (`d <2026-08`, `d >2026-08`)|1]] | absolute date ranges | 🕓 Pending | — |
| [[#Phase 2 — Boolean OR and grouping|2]] | `d 2024 or 2025 or 2y` | 🕓 Pending | — |
| [[#Phase 3 — Arbitrary header specs|3]] | `delivered-to:joe`, `x-mailer.name:mailmate` | 🕓 Pending | — |
| [[#Phase 4 — Message-state specs (unread, flagged, attachments)|4]] | quicksearch equivalents for `is:` / `has:` | 🕓 Pending | — |

## Context

The gem's `mmsearch` / MCP `search` implements a subset of MailMate's toolbar quicksearch: single-letter modifiers (`f t c s a b m d T`), AND-only combination, `!` negation on any operand, and dates as relative windows (`Nd/Nw/Nm/Ny` → `[today−N, ∞)`) or absolute points (`Y`, `Y-M`, `Y-M-D` → that day/month/year exactly). Parsing lives in `Mailmate::CLI::Search#parse_search` (`lib/mailmate/cli/search.rb`), date compilation in `compile_date_range`, evaluation in `matches?`.

While building the foreign-syntax translator (`SearchSyntax.translate`, shipped 2026-08-11), we catalogued what the MailMate app's search accepts that the gem does not. This doc is that catalog. The translator raised the stakes slightly: some foreign tokens (`before:X`, `older_than:N`) only became translatable because generic negation already covered them, and others (`is:unread`, `has:attachment`) remain untranslatable purely because the target syntax below doesn't exist yet — each phase here unlocks a corresponding translator upgrade.

> [!note] Negation on dates already works — it was a documentation gap, not a code gap
> `matches?` applies the `!` negation flag uniformly across all spec types, including `:date`. So `d !3d` (received more than 3 days ago) has worked all along; it just wasn't documented. Fixed 2026-08-11 by adding it to the shared `SearchSyntax` rules/examples. It is also what makes `before:`/`older_than:` translations exact today: `before:X` → `d !Nd` negates the inclusive window `[X, ∞)`, leaving "strictly before X" — Gmail's exact `before:` semantics.

## Phase 1 — Date comparisons (`d <2026-08`, `d >2026-08`)

The MailMate app accepts comparison prefixes on absolute dates: `d <2026-08` (before August 2026), `d >2026-08` (after August 2026). The gem's `compile_date_range` has no comparison form — absolute dates compile only to their own exact range.

If pursued: extend `compile_date_range` to recognize a leading `<` or `>` on the term. The existing integer-range representation makes this nearly free — `>2026-08` is `[20260901, 99991231]` (exclusive of the named period, matching `!`-negation-of-window semantics) and `<2026-08` is `[0, 20260731]`. Decide and document inclusivity explicitly; the app's own behavior is the reference (verify against a live mailbox, not the manual alone). Tokenizer note: `<`/`>` must survive `parse_search`'s operand handling and compose with `!` sensibly (probably: reject `d !<X` as contradictory rather than define it).

Unlocks in the translator: `before:X` / `until:X` → `d <X` directly (today they detour through day-arithmetic to `d !Nd`, which is exact but unreadable in the announcement), plus month/year-precision before/after (`before:2026-05` currently refuses since day arithmetic needs a day).

## Phase 2 — Boolean OR and grouping

The app accepts `d 2024 or 2025 or 2y`; the gem is AND-only (`RULES` says so explicitly). Specs are a flat `[[field, term, negate], ...]` evaluated with `specs.all?`.

If pursued: smallest honest version is OR between *consecutive same-modifier* specs (`d 2024 or d 2025`), which keeps the flat list — each spec gains an `:or` link to its neighbor and `matches?` groups runs. Full grouping (`(f bob or f ann) s invoice`) means a real expression tree; the gem already has a lexer/parser/AST for smart-mailbox filter strings (`lib/mailmate/lexer.rb`, `parser.rb`, `ast.rb`), so the honest full version is probably "compile quicksearch into that AST" rather than growing `parse_search` a second parser. Cost check first: `order_specs`' cost-ranked short-circuiting (date-reject before body-match) must survive whatever shape wins.

## Phase 3 — Arbitrary header specs

The app can search any header by name, including structured sub-paths: `delivered-to:joe`, `x-mailer.name:mailmate`. The gem has only the fixed modifier set.

If pursued, two open questions before code:

1. **Syntax collision with the foreign-token translator.** `delivered-to:joe` is exactly the `key:value` shape that `SearchSyntax.translate` inspects and `zero_result_hint` flags. Rule needs deciding up front — e.g. known foreign keys keep translating, anything else with a `:` becomes a real header spec (which would *retire* the "searched as literal text" trap wholesale — likely the right end state, and worth calling out as the phase's real payoff).
2. **Index coverage.** Fixed modifiers ride MailMate's per-header indexes (`#from#lc` etc.). Arbitrary headers may have no index, forcing `Mail.read` per candidate — fine as a correctness fallback, but the cost cliff should be visible (a note in `--help`, or a spec-cost tier that evaluates these last, as body matching does today).

Verify the app's actual sub-path vocabulary (`.name`, `.address`, others?) against MailMate's manual/behavior before implementing.

## Phase 4 — Message-state specs (unread, flagged, attachments)

Not in the user-reported gap list, but it is the remaining untranslatable-foreign-key family: `is:unread`, `is:flagged`, `has:attachment` have no quicksearch target. The gem already reads flag state (the `flags` output column comes from the `#flags` index), so the data exists; only search-side syntax is missing. The app's quicksearch state vocabulary should be checked first so we adopt its spelling rather than inventing one.

## Recommendation

Phase 1 first — smallest change, immediately improves translator output readability, and its inclusivity decision is prerequisite thinking for Phase 2's date examples anyway. Phase 3 is the largest payoff (it dissolves the literal-text trap entirely) but has the widest blast radius through the translator contract; do it after 1 while the range semantics are fresh. Phases 2 and 4 are independent and can wait for demand.
