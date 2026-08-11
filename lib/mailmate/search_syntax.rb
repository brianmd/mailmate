# frozen_string_literal: true

require "date"

module Mailmate
  # THE one description of quicksearch syntax. Both surfaces that teach the
  # syntax — `mmsearch --help` and the MCP `search` tool description — render
  # from the tables here, so the two can no longer drift apart (they already
  # had: the CLI said "Nd|Nw|Nm|Ny (relative), or Y, Y-M, Y-M-D" while the MCP
  # said "Y, Y-M, Y-M-D, or relative 1d/2w/3m/1y" — same rules, two wordings,
  # two things to remember to update).
  #
  # Downstream consumers should POINT at these surfaces rather than restate
  # them. A copy of the syntax in someone else's system prompt is a copy that
  # goes stale the next time a modifier is added here.
  module SearchSyntax
    # [spec, meaning]. Order is the teaching order, not alphabetical.
    MODIFIERS = [
      ["<term>",   "common headers (from/to/cc/subject) OR body contains <term>"],
      ["f <term>", "from contains"],
      ["t <term>", "to/cc (recipients) contains"],
      ["c <term>", "cc contains"],
      ["s <term>", "subject contains"],
      ["a <term>", "any address header contains"],
      ["b <term>", "body contains"],
      ["m <term>", "common headers OR body (same as a bare term)"],
      ["d <date>", "received date: Nd|Nw|Nm|Ny (relative), or Y, Y-M, Y-M-D"],
      ["T <tag>",  "tag / IMAP keyword contains (K is a synonym)"],
    ].freeze

    EXAMPLES = [
      ["f substack d 7d",         "from Substack in the last 7 days"],
      ["s \"invoice due\" !draft", "subject has 'invoice due', not 'draft'"],
      ["d 2026-05",               "received in May 2026"],
      ["d 2026-08-10",            "received on one specific day"],
      ["d 1d",                    "received in the last day (the default)"],
      ["T urgent",                "tagged 'urgent'"],
    ].freeze

    RULES = [
      "Specs combine with AND (no or/parens yet).",
      "Wrap multi-word terms in \"double quotes\".",
      "Prefix an operand with ! to negate: f !smith = from does NOT contain smith.",
      "Negation works on dates too: d !3d = received MORE than 3 days ago.",
    ].freeze

    # Search keys from OTHER mail systems (Gmail, Outlook, Apple Mail, IMAP
    # dialects). Quicksearch has no `key:value` form at all, so a term like
    # `date:today` is not a syntax error — it parses as a bare term and
    # searches for the literal string "date:today" in headers and body, which
    # matches nothing. That silence is the whole problem this list exists to
    # break: an agent or a person gets an empty result set that is
    # indistinguishable from "your mail really has nothing", and believes it.
    FOREIGN_KEYS = %w[
      after before older newer older_than newer_than on since until
      date sent received time
      from to cc bcc subject body
      is has in label folder mailbox category filename
    ].freeze

    # Spec placeholders for the zero-result hint, for foreign keys whose value
    # translate() could NOT rewrite (e.g. `after:8am`). Keys absent here still
    # get flagged, just without a suggested rewrite.
    EQUIVALENTS = {
      "from" => "f <term>", "to" => "t <term>", "cc" => "c <term>",
      "subject" => "s <term>", "body" => "b <term>", "label" => "T <tag>",
      "date" => "d <date>", "sent" => "d <date>", "received" => "d <date>",
      "on" => "d <date>", "after" => "d <date>", "since" => "d <date>",
      "before" => "d !<Nd>", "until" => "d !<Nd>",
      "newer_than" => "d Nd", "older_than" => "d !Nd",
      "newer" => "d Nd", "older" => "d !Nd",
    }.freeze

    # Foreign header-ish keys with a direct quicksearch spec. The value
    # carries over unchanged, so these translate regardless of what it is.
    HEADER_EQUIV = {
      "from" => "f", "to" => "t", "cc" => "c",
      "subject" => "s", "body" => "b", "label" => "T",
    }.freeze

    # The --help table for the translator. Symbolic, not computed — <N> is
    # resolved against the current date at translation time.
    TRANSLATIONS_HELP = [
      ["from:bob   (to: cc: subject: body: label:)", "f bob   (t c s b T)"],
      ["-from:bob or !from:bob",                     "f !bob"],
      ["date:today / date:yesterday",                "d 0d / d <that day>"],
      ["date:2026-03-05 or date:3/5/2026 (M/D/Y)",   "d 2026-03-05"],
      ["newer_than:2d / older_than:2w",              "d 2d / d !2w"],
      ["after:<day> or since:<day>",                 "d <N>d      (N = days since <day>)"],
      ["before:<day>",                               "d !<N>d"],
    ].freeze

    module_function

    # The shared syntax reference, indented for embedding. Used verbatim by
    # `mmsearch --help` and by the MCP tool description.
    def reference(indent: "  ")
      width = MODIFIERS.map { |spec, _| spec.length }.max
      lines = []
      RULES.each { |r| lines << "#{indent}#{r}" }
      lines << ""
      MODIFIERS.each { |spec, meaning| lines << "#{indent}  #{spec.ljust(width)}  #{meaning}" }
      lines << ""
      lines << "#{indent}Examples:"
      ex_width = EXAMPLES.map { |q, _| q.length }.max
      EXAMPLES.each { |q, meaning| lines << "#{indent}  #{q.ljust(ex_width)}  #{meaning}" }
      lines.join("\n")
    end

    # One token: an (optionally key:-prefixed) quoted string, or a bare run
    # of non-space. Quoted regions survive as single tokens so translate()
    # can leave a deliberate literal search (`s "date:today"`) alone.
    TOKEN_RX = /(?:[-!]?[A-Za-z_]+:)?"[^"]*"|(?:[-!]?[A-Za-z_]+:)?'[^']*'|\S+/

    # Rewrite foreign `key:value` tokens to their exact quicksearch
    # equivalent, leaving everything else byte-for-byte intact. Returns
    # [query, notes] where notes is [[original_token, replacement], ...] —
    # callers MUST surface the notes (stderr, tool result); a silent rewrite
    # would show the reader a query that never ran.
    #
    # Only rewrites where the equivalence is exact. A foreign key whose value
    # can't be translated faithfully (`after:8am`, `date:next week`) stays in
    # the query as literal text, and zero_result_hint still flags it there.
    def translate(query, today: Date.today)
      notes = []
      translated = query.to_s.gsub(TOKEN_RX) do |token|
        replacement = translate_token(token, today)
        notes << [token, replacement] if replacement
        replacement || token
      end
      [translated, notes]
    end

    # The stderr/tool-result announcement for a rewritten query. nil when
    # nothing was rewritten.
    def translation_notice(notes)
      return nil if notes.empty?

      width = notes.map { |from, _| from.length }.max
      lines = ["translated foreign search syntax to MailMate quicksearch (`mmsearch --help`):"]
      notes.each { |from, to| lines << "  #{from.ljust(width)}  ->  #{to}" }
      lines.join("\n")
    end

    # The --help table, indented for embedding.
    def translation_reference(indent: "  ")
      width = TRANSLATIONS_HELP.map { |from, _| from.length }.max
      lines = TRANSLATIONS_HELP.map { |from, to| "#{indent}  #{from.ljust(width)}  ->  #{to}" }
      lines << ""
      lines << "#{indent}Keys with no equivalent (is: has: in: filename: ...) are searched as"
      lines << "#{indent}literal text; an empty result will call them out."
      lines.join("\n")
    end

    # Foreign `key:value` tokens in a query, lowercased keys, in order of
    # appearance and de-duplicated. Quoted regions are skipped: a deliberate
    # search for the literal text `s "date:today"` is not a mistake.
    def foreign_tokens(query)
      unquoted = query.to_s.gsub(/"[^"]*"|'[^']*'/, " ")
      unquoted.scan(/(?<![\w-])!?([A-Za-z_]+):(\S*)/).filter_map do |key, value|
        k = key.downcase
        next unless FOREIGN_KEYS.include?(k)
        ["#{key}:#{value}", k]
      end.uniq { |_token, k| k }
    end

    # The advisory a caller should print when a search matched NOTHING and the
    # query carries foreign syntax. nil when there is nothing to say — an
    # ordinary empty result stays silent, because polling for mail that has
    # not arrived yet is a normal, correct thing to do.
    def zero_result_hint(query)
      tokens = foreign_tokens(query)
      return nil if tokens.empty?

      quoted = tokens.map { |token, _| "`#{token}`" }.join(", ")
      lines = ["0 results, and #{quoted} #{tokens.size == 1 ? "is not" : "are not"} " \
               "MailMate quicksearch syntax — it was searched for as literal text."]
      tokens.each do |token, key|
        eq = EQUIVALENTS[key] or next
        lines << "  #{token}  ->  #{eq}"
      end
      lines << "Run `mmsearch --help` for the full syntax."
      lines.join("\n")
    end

    # ---- translation internals -------------------------------------------

    # nil = not a rewritable token (not key:value, unknown key, or a value
    # with no faithful equivalent).
    def translate_token(token, today)
      m = token.match(/\A(?<neg>[-!])?(?<key>[A-Za-z_]+):(?<value>.+)\z/m)
      return nil unless m

      key   = m[:key].downcase
      value = unquote(m[:value])
      return nil if value.empty?

      if (spec = HEADER_EQUIV[key])
        negated = !m[:neg].nil?
        # `f !"a b"` won't tokenize (the ! detaches the quotes) — leave a
        # negated multi-word value alone rather than emit a broken spec.
        return nil if negated && value =~ /\s/
        operand = value =~ /\s/ ? "\"#{value}\"" : value
        return "#{spec} #{negated ? "!" : ""}#{operand}"
      end

      # Date keys: Gmail has no negated date form, so a -/! prefix here means
      # the caller is inventing syntax — don't guess at intent.
      return nil if m[:neg]

      case key
      when "date", "on", "sent", "received", "time"
        translate_point_date(value, today)
      when "after", "since"
        translate_after(value, today)
      when "before", "until"
        translate_before(value, today)
      when "newer_than", "newer"
        (rel = parse_relative(value)) && "d #{rel}"
      when "older_than", "older"
        (rel = parse_relative(value)) && "d !#{rel}"
      end
    end

    def unquote(value)
      case value
      when /\A"(.*)"\z/m, /\A'(.*)'\z/m then Regexp.last_match(1)
      else value
      end
    end

    # A day-, month-, or year-precision point in time. `d <day>` matches
    # exactly that day in the engine, so these are exact.
    def translate_point_date(value, today)
      v = value.downcase
      return "d 0d" if v == "today"
      return "d #{(today - 1).strftime("%Y-%m-%d")}" if v == "yesterday"
      # `date:8/10/2026-today` (seen in real transcripts): a range whose end
      # is now IS an after-window.
      return translate_after(v.delete_suffix("-today"), today) if v.end_with?("-today")
      return "d #{v}" if v =~ /\A\d+[dwmy]\z/

      if (day = parse_day(v))
        "d #{day.strftime("%Y-%m-%d")}"
      elsif v =~ %r{\A(\d{4})[-/.](\d{1,2})\z}
        format("d %04d-%02d", Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
      elsif v =~ /\A\d{4}\z/
        "d #{v}"
      end
    end

    # `d Nd` compiles to the inclusive window [today-N, ∞) — exactly
    # after:/since: semantics (Gmail's after: includes the named day).
    def translate_after(value, today)
      v = value.downcase
      return "d 0d" if v == "today"
      return "d 1d" if v == "yesterday"

      day = parse_day(v) or return nil
      n = (today - day).to_i
      n >= 0 ? "d #{n}d" : nil
    end

    # Negating that window leaves [., today-N) — exactly before: semantics
    # (Gmail's before: excludes the named day).
    def translate_before(value, today)
      v = value.downcase
      return "d !0d" if v == "today"

      day = parse_day(v) or return nil
      n = (today - day).to_i
      n >= 0 ? "d !#{n}d" : nil
    end

    # Gmail relative units (d/m/y, plus w) carry over as-is: `d N<u>` uses
    # the same calendar arithmetic.
    def parse_relative(value)
      value =~ /\A(\d+)\s*([dwmy])\z/ ? "#{Regexp.last_match(1)}#{Regexp.last_match(2)}" : nil
    end

    # Y-M-D (any of - / . separators) or US M/D/Y. Two-digit years are
    # ambiguous across dialects — refused rather than guessed.
    def parse_day(value)
      parts = value.split(%r{[-/.]})
      return nil unless parts.size == 3 && parts.all? { |p| p =~ /\A\d+\z/ }

      y, m, d =
        if parts[0].length == 4
          [parts[0], parts[1], parts[2]]
        elsif parts[2].length == 4
          [parts[2], parts[0], parts[1]]
        end
      return nil unless y

      y, m, d = y.to_i, m.to_i, d.to_i
      Date.valid_date?(y, m, d) ? Date.new(y, m, d) : nil
    end
  end
end
