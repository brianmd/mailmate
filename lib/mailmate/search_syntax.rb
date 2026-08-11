# frozen_string_literal: true

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

    # Best-effort translation for the foreign keys that have an exact
    # quicksearch equivalent. Keys absent here still get flagged, just without
    # a suggested rewrite.
    EQUIVALENTS = {
      "from" => "f <term>", "to" => "t <term>", "cc" => "c <term>",
      "subject" => "s <term>", "body" => "b <term>", "label" => "T <tag>",
      "date" => "d <date>", "sent" => "d <date>", "received" => "d <date>",
      "on" => "d <date>", "after" => "d <date>", "since" => "d <date>",
      "before" => "d <date>", "newer_than" => "d Nd", "older_than" => "d Nd",
    }.freeze

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
  end
end
