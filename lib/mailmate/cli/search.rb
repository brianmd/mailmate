# frozen_string_literal: true

require "mail"
require "optparse"
require "date"
require "csv"

module Mailmate
  module CLI
    # `mmsearch` — search MailMate's `.eml` files using a subset of MailMate's
    # quicksearch syntax. Output is CSV with optional column-aligned padding.
    #
    # Ported from the standalone mailmate-search script. See `~/.claude/skills/email/SKILL.md`
    # for usage examples and the search-string syntax reference.
    # @api private
    module Search
      extend self

      MODIFIERS = {
        "f" => :from, "t" => :recipients, "c" => :cc, "s" => :subject,
        "a" => :address_any, "b" => :body, "m" => :message_or_body,
        "d" => :date, "T" => :tag, "K" => :keyword
      }.freeze

      # Filter modifiers that read from MailMate's per-header indexes —
      # zero .eml reads when matching. `field_value` consults them via
      # `header_index_value_lc`. Kept as a constant for documentation;
      # the prefilter no longer uses it (indexes are the prefilter now).
      INDEXED_FILTER_FIELDS = %i[from recipients cc subject address_any any].freeze

      VALID_FIELDS = %w[id path mailbox from to cc bcc reply-to subject date time
                        message-id message-url references in-reply-to
                        direction party flags read archive tags keywords].freeze

      HEADER_LABELS = {
        "direction" => "dir",
        "read"      => "r",
        "archive"   => "a",
      }.freeze

      # All output fields are now index-tier: MailMate maintains a per-header
      # binary index under Database.noindex/Headers/, so extracting from/to/
      # subject/etc. doesn't require opening the .eml. Spec/filter matching
      # (the `f`/`t`/`s` modifiers in the search string) still parses the
      # .eml header block — migrating that side is a separate change.
      FIELD_TIERS = {
        "id" => :index, "path" => :index, "mailbox" => :index,
        "date" => :index, "time" => :index,
        "read" => :index,
        "archive" => :index,
        "flags" => :index,
        "tags" => :index,
        "keywords" => :index,
        "from" => :index, "to" => :index, "cc" => :index, "bcc" => :index,
        "reply-to" => :index, "subject" => :index, "message-id" => :index,
        "message-url" => :index,
        "references" => :index, "in-reply-to" => :index,
        "direction" => :index, "party" => :index,
      }.freeze

      DEFAULT_SEARCH = "d 1d"
      DEFAULT_FIELDS = "id flags date time direction party subject"

      def run(argv)
        opts = {
          mailbox: "all", limit: nil, headers_only: false, all: false,
          exclude_quoted: false,
          header: true, align: true, sort: :asc,
        }

        parser = build_parser(opts)
        parser.parse!(argv)

        search_string = argv[0] || DEFAULT_SEARCH
        fields_arg    = (opts[:fields] || argv[1] || DEFAULT_FIELDS).to_s.strip
        # `+...` means "defaults plus these"; bare list = exactly those columns.
        # Defaults already include `id` as the first column, so `+x` keeps id
        # automatic while a bare list lets callers omit it (useful for
        # `mmsearch foo 'message-id' | sort | uniq` where leading per-row ids
        # would defeat the dedup).
        fields_arg    = "#{DEFAULT_FIELDS} #{fields_arg[1..]}" if fields_arg.start_with?("+")
        # Split on whitespace OR commas (or both) so callers can pass
        # 'subject message-id', 'subject,message-id', or any mix.
        fields = fields_arg.split(/[\s,]+/).reject(&:empty?).uniq

        imap_root = Mailmate.config.imap_root
        unless File.directory?(imap_root)
          warn "MailMate IMAP root not found: #{imap_root}"
          return 1
        end

        unknown = fields - VALID_FIELDS
        unless unknown.empty?
          warn "Unknown field(s): #{unknown.join(", ")}"
          warn "Valid: #{VALID_FIELDS.join(", ")}"
          return 2
        end

        dirs, smart_filters, smart_graph = resolve_mailbox_with_graph(opts[:mailbox])
        if dirs.empty?
          warn "No mailbox directories resolved."
          return 1
        end

        specs = order_specs(parse_search(search_string))

        # Compose + parse the smart-mailbox filter exactly once. The same AST
        # feeds the evaluator, the tier classifier, and the literals extractor.
        composed_ast = nil
        composed_str = nil
        smart_evaluator =
          if smart_filters.any?
            composed_str = compose_smart_filters(smart_filters)
            begin
              composed_ast = Mailmate.compile_filter(composed_str)
              var_resolver = smart_graph ? Mailmate::VarResolver.new(smart_graph) : nil
              Mailmate::Evaluator.new(composed_ast, var_resolver: var_resolver)
            rescue Mailmate::Lexer::Error, Mailmate::Parser::Error => e
              warn "Smart-mailbox filter parse error: #{e.message}\n  filter: #{composed_str}"
              return 1
            end
          end

        filter_tier      = composed_ast ? Mailmate::FilterClassifier.tier(composed_ast) : :index
        # Every spec is now index-tier. Body matching reads MailMate's
        # `#unquoted#lc`/`#quoted#lc` indexes (zero .eml read for indexed
        # messages); `body_value` lazily Mail.reads the .eml for the rare
        # misses. Header/tag/date specs all hit per-header indexes too.
        specs_tier = :index
        fields_tier_     = fields_tier(fields)
        filter_only_tier = Mailmate::FilterClassifier.combine_tiers(filter_tier, specs_tier)
        load_tier        = Mailmate::FilterClassifier.combine_tiers(filter_only_tier, fields_tier_)

        smart_literals = composed_ast ? Mailmate::FilterClassifier.header_literals(composed_ast) : []

        rows = collect_rows(
          dirs: dirs, specs: specs, fields: fields,
          smart_evaluator: smart_evaluator, smart_literals: smart_literals,
          filter_only_tier: filter_only_tier, load_tier: load_tier,
          opts: opts,
        )

        sort_rows!(rows, opts[:sort])
        emit_output(rows, fields, opts)
        # A query written in another mail system's dialect is not a syntax
        # error here — it parses as a literal term and quietly matches
        # nothing. Callers (people and agents alike) read that empty result
        # as "no such mail" and stop. Say so on stderr, so stdout stays
        # clean CSV and the exit status stays 0: the search DID run, it just
        # cannot have found what the caller meant.
        if rows.empty? && (hint = Mailmate::SearchSyntax.zero_result_hint(search_string))
          warn hint
        end
        0
      end

      # ---- sort ---------------------------------------------------------------

      # Sorts `rows` in place by the message's absolute send instant (UTC), so
      # senders in different timezones still order correctly. The first column
      # is always `id` (forced in `run`), which lets us hit the `#date` index
      # without re-reading any .eml.
      def sort_rows!(rows, mode)
        return rows if mode == :none || rows.size < 2
        reader = Mailmate::IndexReader.for("#date") rescue nil
        epoch = Time.at(0)
        rows.sort_by! do |r|
          s = reader && (reader.value_for(r[0].to_i) rescue nil)
          (s && !s.empty? && (fast_time(s) || (Time.parse(s) rescue nil))) || epoch
        end
        rows.reverse! if mode == :desc
        rows
      end

      # ---- option parsing -----------------------------------------------------

      def build_parser(opts)
        OptionParser.new do |o|
          o.banner = "Usage: mmsearch [search-string] [fields] [options]"
          o.separator ""
          o.separator "Search MailMate's `.eml` files. Output is CSV with column-aligned padding."
          o.separator ""
          o.separator "POSITIONAL ARGS"
          o.separator "  search-string  Quicksearch expression. Default: 'd 1d'. Pass '' to disable."
          o.separator "  fields         Columns to show. Space- or comma-separated."
          o.separator "                 Default: 'id flags date time direction party subject'."
          o.separator "                 Bare list = exactly those columns (omit 'id' to drop it)."
          o.separator "                 Prefix with '+' to extend the defaults: '+tags' = defaults + tags."
          o.separator ""
          o.separator "OPTIONS"
          o.on("--mailbox X", "Mailbox to search (default: all)") { |v| opts[:mailbox] = v }
          o.on("--fields F", "Fields list (alt to 2nd positional)") { |v| opts[:fields] = v }
          o.on("--limit N", Integer, "Stop after N matches") { |n| opts[:limit] = n }
          o.on("--headers-only", "Skip body matching entirely") { opts[:headers_only] = true }
          o.on("--all", "Include un-indexed messages in body matching by lazily reading and parsing each .eml. Slow (tens of seconds to minutes on large archives). Default behavior matches MailMate's UI: only check messages MailMate has body-indexed — fast, but bounded.") { opts[:all] = true }
          o.on("--exclude-quoted", "Match body only against #unquoted text — skip MailMate's #quoted index (forwarded/replied-to text). Tightens search to fresh content; gets you closer to MailMate UI's body-search result set, at the cost of missing hits in quoted sections.") { opts[:exclude_quoted] = true }
          o.on("--no-header", "Suppress column header row") { opts[:header] = false }
          o.on("--no-align", "Plain CSV (no column padding)") { opts[:align] = false }
          o.on("--sort MODE", %w[asc desc none],
               "Sort rows by date+time: asc (default), desc, none") { |v| opts[:sort] = v.to_sym }
          o.separator ""
          o.separator "SEARCH-STRING SYNTAX"
          o.separator "  Mirrors MailMate's toolbar quicksearch. There is no key:value form —"
          o.separator "  `date:today` is not a filter, it is a search for that literal text."
          o.separator Mailmate::SearchSyntax.reference(indent: "  ")
          o.separator "  (b also takes --all to include un-indexed messages.)"
          o.separator ""
          o.separator "FIELDS (for the fields argument / --fields)"
          o.separator "  id          eml-id (always included as first column)"
          o.separator "  path        full path to the .eml file"
          o.separator "  mailbox     account/mailbox path (no /Messages/<id>.eml suffix)"
          o.separator "  from        From header"
          o.separator "  to          To header"
          o.separator "  cc          Cc header"
          o.separator "  bcc         Bcc header"
          o.separator "  reply-to    Reply-To header"
          o.separator "  subject       Subject header"
          o.separator "  message-id    RFC Message-ID header"
          o.separator "  message-url   message://%3C<MID>%3E — portable, paste-ready cross-machine ref"
          o.separator "  references    RFC References header (space-joined when multiple)"
          o.separator "  in-reply-to   RFC In-Reply-To header"
          o.separator "  date        received date, YYYY-MM-DD (local time)"
          o.separator "  time        received time, HH:MM (local time)"
          o.separator "  direction   '→' outbound, '←' inbound (column header: 'dir')"
          o.separator "  party       counterparty (recipients if outbound, sender if inbound)"
          o.separator "  flags       archive + read combined, e.g. 'AR', 'PU'"
          o.separator "  read        'R' read or 'U' unread (column header: 'r')"
          o.separator "  archive     'A' archived or 'P' present elsewhere (column header: 'a')"
          o.separator "  tags        user tags (IMAP keywords), comma-joined; system flags (\\… , $…) excluded"
          o.separator "  keywords    raw IMAP keyword list (incl. \\Seen, \\Draft, \\Flagged, \$Forwarded, user tags)"
        end
      end

      # ---- mailbox resolution -------------------------------------------------

      def all_message_dirs
        Dir.glob("#{Mailmate.config.imap_root}/*/**/Messages").select { |p| File.directory?(p) }
      end

      def resolve_account(name)
        root = Mailmate.config.imap_root
        return name if File.directory?("#{root}/#{name}")
        encoded = name.gsub("@", "%40")
        candidates = Dir.glob("#{root}/#{encoded}@*").map { |p| File.basename(p) }
        case candidates.size
        when 0 then nil
        when 1 then candidates.first
        else
          warn "Ambiguous account '#{name}': #{candidates.join(", ")}"
          nil
        end
      end

      def resolve_mailbox(arg)
        root = Mailmate.config.imap_root
        return [all_message_dirs, []] if arg == "all"

        if arg.include?("/")
          account, rest = arg.split("/", 2)
          if (encoded = resolve_account(account))
            nested = rest.split("/").map { |s| "#{s}.mailbox" }.join("/")
            cand = "#{root}/#{encoded}/#{nested}/Messages"
            return [[cand], []] if File.directory?(cand)
          end
        end

        if (encoded = resolve_account(arg))
          dirs = Dir.glob("#{root}/#{encoded}/**/Messages").select { |p| File.directory?(p) }
          return [dirs, []]
        end

        matches = Dir.glob("#{root}/*/**/#{arg}.mailbox/Messages").select { |p| File.directory?(p) }
        return [matches, []] unless matches.empty?

        # Fall back: try MailMate's smart-mailbox graph.
        graph = Mailmate::MailboxGraph.load
        if (uuid = graph.by_name[arg]) || graph.by_uuid[arg]
          uuid ||= arg
          res = Mailmate::SourceResolver.new(graph).resolve(uuid)
          return [res[:dirs], res[:filters], graph]
        end

        warn "Mailbox not resolved: '#{arg}'."
        [[], []]
      end

      def resolve_mailbox_with_graph(arg)
        result = resolve_mailbox(arg)
        result.size == 2 ? [*result, nil] : result
      end

      def compose_smart_filters(filters)
        return "" if filters.empty?
        return filters.first if filters.size == 1
        "(#{filters.map { |f| "(#{f})" }.join(" and ")})"
      end

      # ---- search-string parsing ----------------------------------------------

      def tokenize(str)
        tokens = []
        i = 0
        while i < str.length
          c = str[i]
          if c == " " || c == "\t"
            i += 1
          elsif c == "\""
            j = str.index("\"", i + 1) || str.length
            tokens << str[(i + 1)...j]
            i = j + 1
          else
            j = i
            j += 1 while j < str.length && str[j] != " "
            tokens << str[i...j]
            i = j
          end
        end
        tokens
      end

      def parse_search(str)
        tokens = tokenize(str)
        specs = []
        i = 0
        while i < tokens.size
          tok = tokens[i]
          field = MODIFIERS[tok]
          if field && i + 1 < tokens.size
            operand = tokens[i + 1]
            negate = operand.start_with?("!")
            operand = operand[1..] if negate
            specs << [field, operand.downcase, negate]
            i += 2
          else
            negate = tok.start_with?("!")
            operand = negate ? tok[1..] : tok
            # Bare terms default to MailMate's "Common" specifier — common
            # headers OR body — matching the UI quicksearch behavior. Pass
            # --headers-only to skip the body scan when speed matters.
            specs << [:message_or_body, operand.downcase, negate]
            i += 1
          end
        end
        specs
      end

      # Static cost rank per spec field for AND evaluation order: compiled
      # date compare < header/tag index lookup < body matching (resolves
      # part-ids and walks every body segment). Used by order_specs.
      SPEC_COST = {
        date: 0,
        from: 1, recipients: 1, cc: 1, subject: 1, address_any: 1, any: 1,
        tag: 1, keyword: 1,
        body: 2, message_or_body: 2,
      }.freeze

      # Evaluate cheap, selective specs before expensive ones. specs combine
      # with AND (order-independent), and matches? short-circuits on the
      # first miss — so `b invoice d 7d` should date-reject 47k messages
      # before body matching ever runs, not after. Stable within a cost rank
      # to keep the user's order deterministic.
      def order_specs(specs)
        specs.sort_by.with_index { |(field, _term, _negate), i| [SPEC_COST.fetch(field, 1), i] }
      end

      # ---- date matching ------------------------------------------------------
      #
      # The `#date` index stores fixed-format strings ("2026-03-19 18:55:19
      # -0600", sender-local time with varying UTC offsets — NOT lexically
      # comparable). date_matches? runs once per candidate message, so the
      # hot path avoids Time.parse (~10× slower than slicing) and per-call
      # cutoff arithmetic: terms compile once to an inclusive [lo, hi] range
      # of YYYYMMDD integers, and the indexed value slices straight to the
      # same integer form. Calendar-date comparison semantics are unchanged.

      # Compiled day-range for a date term, memoized per term. nil = term
      # can't match anything. The memo resets when the calendar day rolls
      # over so relative terms ("1d") stay correct in long-lived processes
      # (the MCP server).
      def date_range_for(term)
        today = Date.today
        if @date_ranges_day != today
          @date_ranges_day = today
          @date_ranges = {}
        end
        return @date_ranges[term] if @date_ranges.key?(term)
        @date_ranges[term] = compile_date_range(term, today)
      end

      def compile_date_range(term, today)
        if term =~ /\A(\d+)([dwmy])\z/
          n, u = Regexp.last_match(1).to_i, Regexp.last_match(2)
          cutoff = case u
                   when "d" then today - n
                   when "w" then today - (n * 7)
                   when "m" then today << n
                   when "y" then today << (n * 12)
                   end
          return [ymd_int(cutoff), 9999_12_31]
        end

        parts = term.tr("/.", "-").split("-")
        y = parts[0].to_i
        return nil if y.zero?
        case parts.size
        when 1 then [y * 10_000 + 101, y * 10_000 + 1231]
        when 2 then [y * 10_000 + parts[1].to_i * 100 + 1, y * 10_000 + parts[1].to_i * 100 + 31]
        when 3 then [ymd = y * 10_000 + parts[1].to_i * 100 + parts[2].to_i, ymd]
        end
      end

      def ymd_int(d)
        d.year * 10_000 + d.month * 100 + d.day
      end

      # "2026-03-19 …" → 20260319 without Time.parse. nil when the value
      # isn't in the indexed shape (caller falls back to the slow path).
      def fast_ymd(s)
        return nil unless s && s.length >= 10 && s.getbyte(4) == 0x2D && s.getbyte(7) == 0x2D
        y = s[0, 4].to_i
        m = s[5, 2].to_i
        d = s[8, 2].to_i
        return nil if y.zero? || m.zero? || d.zero?
        y * 10_000 + m * 100 + d
      end

      def date_matches?(mail, eml_id, term)
        range = date_range_for(term)
        return false unless range

        ymd = nil
        if eml_id
          s = (reader_for("#date")&.value_for(eml_id.to_i) rescue nil)
          if s && !s.empty?
            ymd = fast_ymd(s)
            if ymd.nil?
              t = (Time.parse(s) rescue nil)
              ymd = t && ymd_int(t.to_date)
            end
          end
        end
        if ymd.nil? && mail
          raw = mail.date
          d = raw.respond_to?(:to_time) ? raw.to_time : raw
          ymd = d && ymd_int(d.to_date)
        end
        return false unless ymd

        ymd >= range[0] && ymd <= range[1]
      rescue StandardError
        false
      end

      # ---- field-value matching -----------------------------------------------
      #
      # Match haystacks are RAW BYTES (ASCII-8BIT), not scrubbed UTF-8: the
      # index values come straight out of the cache slice and the needle is
      # `term.b`, so substring matching is byte-wise. That's exact for valid
      # UTF-8 (lead bytes can't alias continuation bytes) and saves the
      # dup + force_encoding + scrub allocations per header per message —
      # scrubbing only matters when a value is *emitted*, which extract()
      # still does via header_index_value.

      # Memoized "<name>#lc" strings — interpolating per lookup costs an
      # allocation per header per message.
      LC_NAMES = Hash.new { |h, n| h[n] = "#{n}#lc" }

      # Per-name reader memo for the match loop. IndexReader.for is cached
      # but not free (cache-key allocation + staleness throttle check per
      # call), and the loop calls it several times per message. The memo is
      # keyed to the active db_headers (config swaps in tests) and reset at
      # the top of collect_rows, so one search run sees one consistent index
      # snapshot; staleness is re-checked between runs, which is the same
      # granularity the MCP server needs.
      def reader_for(name)
        dbh = Mailmate.config.db_headers
        if !defined?(@hdr_readers) || @hdr_readers.nil? || @hdr_readers_dbh != dbh
          @hdr_readers = {}
          @hdr_readers_dbh = dbh
        end
        return @hdr_readers[name] if @hdr_readers.key?(name)
        @hdr_readers[name] =
          begin
            Mailmate::IndexReader.for(name)
          rescue ArgumentError
            nil
          end
      end

      def reset_run_caches!
        @hdr_readers = nil
      end

      # Lowercased raw index value for a header — tries `<name>#lc`
      # (MailMate's pre-downcased index) first, falls back to `<name>` +
      # downcase (byte-wise, i.e. ASCII-only — fine: the #lc index exists
      # for every header MailMate matches on, so the fallback is for tests
      # and fresh installs). Returns nil if neither index has a record.
      def header_index_value_lc(eml_id, name)
        v = header_index_value_raw(eml_id, LC_NAMES[name])
        return v unless v.nil?
        header_index_value_raw(eml_id, name)&.downcase
      end

      # Unscrubbed twin of header_index_value, for match paths only.
      def header_index_value_raw(eml_id, name)
        return nil if eml_id.nil?
        reader_for(name)&.value_for(eml_id.to_i)
      end

      # Substring-match haystack for a filter modifier, as raw bytes (mail
      # fallbacks are downcased then `.b`'d so every return path has the
      # same encoding). Index-first; mail fallback only kicks in for the
      # no-index case (tests, fresh installs, unindexed messages).
      def field_value(eml_id, mail, field)
        case field
        when :from
          idx = header_index_value_lc(eml_id, "from")
          return idx if idx && !idx.empty?
          mail ? [Array(mail.from), mail[:from]&.value.to_s].flatten.join(" ").downcase.b : "".b
        when :recipients
          parts = %w[to cc].map { |n| header_index_value_lc(eml_id, n) }.compact.reject(&:empty?)
          return parts.join(" ") unless parts.empty?
          mail ? [Array(mail.to), Array(mail.cc), mail[:to]&.value.to_s, mail[:cc]&.value.to_s].flatten.join(" ").downcase.b : "".b
        when :cc
          idx = header_index_value_lc(eml_id, "cc")
          return idx if idx && !idx.empty?
          mail ? [Array(mail.cc), mail[:cc]&.value.to_s].flatten.join(" ").downcase.b : "".b
        when :subject
          idx = header_index_value_lc(eml_id, "subject")
          return idx if idx && !idx.empty?
          mail ? mail.subject.to_s.downcase.b : "".b
        when :address_any
          parts = %w[from to cc reply-to sender].map { |n| header_index_value_lc(eml_id, n) }.compact.reject(&:empty?)
          return parts.join(" ") unless parts.empty?
          mail ? [mail[:from], mail[:to], mail[:cc], mail[:reply_to], mail[:sender]].compact.map { |h| h.value.to_s }.join(" ").downcase.b : "".b
        end
      end

      # MailMate stores user tags as IMAP keywords in the `#flags` index — not
      # as `X-Keywords`/`Keywords` headers in the .eml — so tag matching has to
      # go through the index, not the parsed mail. Strips `\…` (RFC) and `$…`
      # (Thunderbird/Apple) system flags so substring matches only hit user tags.
      def tag_value(eml_id)
        return "" unless eml_id
        flags = (reader_for("#flags")&.flags_for(eml_id.to_i) || [])
        flags.reject { |f| f.start_with?("\\", "$") }.join(" ").downcase
      end

      def text_body(mail)
        (mail.text_part&.decoded || mail.body.decoded).to_s.force_encoding("UTF-8").scrub.downcase
      rescue StandardError
        ""
      end

      # Lowercased body substring-match haystack. Three-layer fallback:
      #
      #   1. MailMate's #unquoted#lc + #quoted#lc indexes — pre-decoded,
      #      pre-downcased body text. Zero .eml read. The fast path; covers
      #      the overwhelming majority of indexed mail. Body indexes are
      #      keyed by body-part-id (not envelope-id), so we resolve the
      #      envelope to its child parts via PartLookup, then aggregate every
      #      segment record across both indexes.
      #   2. If no index record AND the caller already has a parsed Mail
      #      object, use text_body(mail) (same as before the migration).
      #   3. If no index record AND no preloaded Mail, lazily Mail.read the
      #      .eml on demand. Slow, but only happens for the rare message
      #      MailMate hasn't body-indexed yet — far cheaper than the old
      #      always-load behavior.
      #
      # `index_only: true` short-circuits after step 1 (no fallback to mail or
      # to disk). Same coverage and speed as MailMate's own UI body search:
      # instant, but limited to messages MailMate has body-indexed.
      def body_value(eml_id, mail, path, index_only: false, exclude_quoted: false)
        texts = body_index_records(eml_id, exclude_quoted: exclude_quoted)
        return texts.join(" ") unless texts.empty?
        return "" if index_only
        return text_body(mail) if mail
        return "" if path.nil?
        begin
          text_body(Mail.read(path))
        rescue StandardError
          ""
        end
      end

      # Lowercased body-text segments from MailMate's #unquoted#lc and
      # #quoted#lc indexes, aggregated across every body-part of the envelope.
      # Returns [] if MailMate hasn't body-indexed the message.
      #
      # Body indexes are keyed by body-part-id and are multi-record (one
      # record per text segment — paragraph/line/table row). For multipart
      # messages we ask PartLookup for the child part-ids. For single-part
      # messages PartLookup returns [] (envelope-id == body-part-id is not
      # recorded in #root-body-part); we fall back to looking up the envelope
      # eml-id directly so those messages still match.
      #
      # `exclude_quoted: true` drops #quoted#lc (forwarded / replied-to text),
      # tightening recall toward MailMate UI's body-search semantics.
      def body_index_records(eml_id, exclude_quoted: false)
        return [] if eml_id.nil?
        envelope = eml_id.to_i
        part_ids = Mailmate::PartLookup.body_parts_of(envelope)
        part_ids = [envelope] if part_ids.empty?

        index_names = exclude_quoted ? %w[#unquoted#lc] : %w[#unquoted#lc #quoted#lc]
        texts = []
        index_names.each do |name|
          reader =
            begin
              Mailmate::IndexReader.for(name)
            rescue ArgumentError
              next
            end
          part_ids.each do |pid|
            reader.values_for(pid).each do |v|
              next if v.nil? || v.empty?
              texts << v.dup.force_encoding("UTF-8").scrub
            end
          end
        end
        texts
      end

      def matches?(mail, eml_id, specs, headers_only, path = nil, index_only: false, exclude_quoted: false)
        specs.all? do |field, term, negate|
          term_b = term.b
          hit =
            case field
            when :from, :recipients, :cc, :subject, :address_any
              field_value(eml_id, mail, field).include?(term_b)
            when :tag, :keyword
              tag_value(eml_id).include?(term_b)
            when :body
              headers_only ? false : body_matches?(eml_id, mail, path, term, term_b, index_only: index_only, exclude_quoted: exclude_quoted)
            when :message_or_body
              common = %i[from recipients subject].any? { |f| field_value(eml_id, mail, f).include?(term_b) }
              common || (!headers_only && body_matches?(eml_id, mail, path, term, term_b, index_only: index_only, exclude_quoted: exclude_quoted))
            when :date
              date_matches?(mail, eml_id, term)
            when :any
              %i[from recipients subject].any? { |f| field_value(eml_id, mail, f).include?(term_b) }
            end
          negate ? !hit : hit
        end
      end

      # ---- body matching --------------------------------------------------
      #
      # Body matching is inverted: instead of fetching and testing every
      # body segment of every candidate message (which reallocates most of
      # the body cache per search), one ids_matching scan per body index
      # finds every part-id containing the term, mapped once to a set of
      # envelope ids. Per message the test is then a hash lookup. The
      # per-message segment walk (body_index_records / body_value) survives
      # as the fallback when the body indexes aren't on disk at all (tests,
      # fresh installs), and the Mail.read fallback for unindexed messages
      # under --all is unchanged.

      def body_matches?(eml_id, mail, path, term, term_b, index_only: false, exclude_quoted: false)
        env = eml_id&.to_i
        cands = env && body_candidates(term_b, exclude_quoted: exclude_quoted)
        if cands
          return true if cands.key?(env)
          return false if index_only
          # Indexed but not a candidate = a real non-match; only unindexed
          # messages get the --all read-the-eml fallback below.
          return false if body_indexed?(env, exclude_quoted: exclude_quoted)
        else
          segs = body_index_records(eml_id, exclude_quoted: exclude_quoted)
          return segs.any? { |s| s.b.include?(term_b) } unless segs.empty?
          return false if index_only
        end
        return text_body(mail).include?(term) if mail
        return false if path.nil?
        begin
          text_body(Mail.read(path)).include?(term)
        rescue StandardError
          false
        end
      end

      # Envelope-id candidate set for a body term: every message with at
      # least one body segment containing the bytes. Returns nil when the
      # body indexes are unavailable (callers fall back to the per-message
      # walk). Memoized per (term, exclude_quoted) and pinned to the reader
      # objects it was built from, so an index rebuild (staleness, reset!)
      # invalidates naturally; the size cap stops distinct-term buildup in
      # the long-lived MCP server.
      def body_candidates(term_b, exclude_quoted: false)
        names = exclude_quoted ? ["#unquoted#lc"] : ["#unquoted#lc", "#quoted#lc"]
        readers = names.map { |n| (Mailmate::IndexReader.for(n) rescue nil) }.compact
        return nil if readers.empty?

        @body_cands ||= {}
        key = [term_b, exclude_quoted]
        entry = @body_cands[key]
        if entry && entry[:readers].size == readers.size &&
           entry[:readers].zip(readers).all? { |a, b| a.equal?(b) }
          return entry[:set]
        end

        @body_cands.clear if @body_cands.size > 32
        set = {}
        readers.each do |r|
          r.ids_matching(term_b).each_key { |pid| set[envelope_of(pid)] = true }
        end
        @body_cands[key] = { readers: readers, set: set }
        set
      end

      # Map a body-part-id back to its envelope (.eml) id via
      # #root-body-part; single-part messages have no entry there (the
      # envelope IS the body part), so fall through to the part-id itself.
      def envelope_of(part_id)
        root = (Mailmate::IndexReader.for("#root-body-part").value_for(part_id) rescue nil)
        root && !root.empty? ? root.to_i : part_id
      end

      # Does this envelope have any body-index records at all? Distinguishes
      # "indexed, doesn't contain the term" (no match) from "MailMate hasn't
      # body-indexed it" (eligible for the --all Mail.read fallback).
      def body_indexed?(env, exclude_quoted: false)
        part_ids = Mailmate::PartLookup.body_parts_of(env)
        part_ids = [env] if part_ids.empty?
        names = exclude_quoted ? ["#unquoted#lc"] : ["#unquoted#lc", "#quoted#lc"]
        names.any? do |n|
          r = (Mailmate::IndexReader.for(n) rescue nil)
          r && part_ids.any? { |pid| r.key?(pid) }
        end
      end

      # ---- pre-filter ---------------------------------------------------------
      #
      # Filter modifiers (f/t/s/c/a) now match through MailMate's per-header
      # indexes — index lookup IS the prefilter, no .eml read needed. The
      # only remaining use of the .eml header-block grep is smart-mailbox
      # filters that reference literal strings in arbitrary headers; those
      # still benefit from a quick header-block scan to skip non-matching
      # messages before any full evaluation.

      def header_block(path)
        bytes = +""
        File.open(path, "rb") do |f|
          while (chunk = f.read(4096))
            bytes << chunk
            idx = bytes.index("\r\n\r\n") || bytes.index("\n\n")
            return bytes[0..idx].downcase if idx
            break if bytes.bytesize > 65_536
          end
        end
        bytes.downcase
      end

      def prefilter_pass?(path, _specs, smart_literals = [])
        return true if smart_literals.empty?
        hdr = header_block(path)
        smart_literals.all? { |lit| hdr.include?(lit) }
      rescue StandardError
        true
      end

      # ---- timestamp ----------------------------------------------------------

      # Slice-parse a `#date` index value ("2026-03-19 18:55:19 -0600") into a
      # Time, preserving the embedded UTC offset. ~10× faster than Time.parse.
      # Returns nil when the value isn't exactly that shape (caller falls back
      # to Time.parse).
      def fast_time(s)
        return nil unless s && s.length >= 25 &&
                          s.getbyte(4) == 0x2D && s.getbyte(7) == 0x2D &&
                          s.getbyte(13) == 0x3A && s.getbyte(16) == 0x3A
        off = s[20, 5]
        return nil unless off.match?(/\A[+-]\d{4}\z/)
        Time.new(s[0, 4].to_i, s[5, 2].to_i, s[8, 2].to_i,
                 s[11, 2].to_i, s[14, 2].to_i, s[17, 2].to_i,
                 "#{off[0, 3]}:#{off[3, 2]}")
      rescue ArgumentError
        nil
      end

      # Absolute send time for an eml_id, preferring the MailMate `#date` index
      # (cheap, no .eml read). Falls back to the parsed mail's Date header.
      def message_time(eml_id, mail)
        s = (Mailmate::IndexReader.for("#date").value_for(eml_id.to_i) rescue nil)
        if s && !s.empty?
          t = fast_time(s) || (Time.parse(s) rescue nil)
          return t if t
        end
        raw = mail&.date
        return nil unless raw
        raw.respond_to?(:to_time) ? raw.to_time : raw
      rescue StandardError
        nil
      end

      # ---- field extraction ---------------------------------------------------

      # MailMate keeps a per-header binary index under Database.noindex/Headers/
      # — one cache/offsets file per RFC header name. Reading from there is
      # O(1) and skips the .eml entirely. Returns nil if the index is missing
      # (e.g. tests against a synthetic config) or if the eml-id isn't in it,
      # so callers can fall back to a parsed `Mail` object.
      #
      # IndexReader returns the cache substring as ASCII-8BIT (raw bytes from
      # File.binread). Force UTF-8 + scrub here so values from the index can
      # safely interleave with UTF-8 strings in joined output rows.
      def header_index_value(eml_id, name)
        return nil if eml_id.nil?
        v = Mailmate::IndexReader.for(name).value_for(eml_id.to_i)
        v && v.dup.force_encoding("UTF-8").scrub
      rescue ArgumentError
        nil
      end

      def index_or_mail(eml_id, name, fallback)
        v = header_index_value(eml_id, name)
        return v if v && !v.empty?
        fallback.to_s
      end

      # First bare email address from a header value, lower-cased. Accepts
      # either "Name <addr>" or "addr"; for comma-separated lists, returns
      # the first one.
      def first_address(value)
        return nil if value.nil? || value.empty?
        first = value.split(",").first.to_s.strip
        addr = first =~ /<([^>]+)>/ ? Regexp.last_match(1) : first
        addr.to_s.downcase
      end

      # Split a comma-separated address-list header value into individual
      # tokens, each kept in its original "Name <addr>" form.
      def split_addresses(value)
        return [] if value.nil? || value.empty?
        value.split(",").map(&:strip).reject(&:empty?)
      end

      def outbound?(path, mail, eml_id = nil)
        return true if path.include?("/Sent Mail.mailbox/") ||
                       path.include?("/Sent Messages.mailbox/") ||
                       path.include?("/Drafts.mailbox/")
        from = first_address(header_index_value(eml_id, "from")) ||
               Array(mail&.from).first.to_s.downcase
        Mailmate::Identity.mine?(from)
      end

      def party_for(eml_id, mail, outbound)
        if outbound
          to_str = index_or_mail(eml_id, "to", mail ? Array(mail.to).join(", ") : "")
          cc_str = index_or_mail(eml_id, "cc", mail ? Array(mail.cc).join(", ") : "")
          tokens = split_addresses(to_str) + split_addresses(cc_str)
          others = Mailmate::Identity.reject_mine(tokens.map { |t| first_address(t) || t })
          others = split_addresses(to_str) if others.empty?
          others.join("; ")
        else
          index_or_mail(eml_id, "from", mail ? Array(mail.from).join("; ") : "")
        end
      end

      def extract(field, eml_id, path, mail)
        case field
        when "id"         then eml_id
        when "path"       then path
        when "mailbox"    then path.sub("#{Mailmate.config.imap_root}/", "").sub(%r{/Messages/[^/]+\.eml\z}, "")
        when "date"
          t = message_time(eml_id, mail)
          Mailmate.localize(t)&.strftime("%Y-%m-%d")
        when "time"
          t = message_time(eml_id, mail)
          Mailmate.localize(t)&.strftime("%H:%M")
        when "read"
          flags = (Mailmate::IndexReader.for("#flags").flags_for(eml_id.to_i) rescue [])
          flags.include?("\\Seen") ? "R" : "U"
        when "archive"
          path.include?("/Archive.mailbox/") ? "A" : "P"
        when "flags"
          archive = path.include?("/Archive.mailbox/") ? "A" : "P"
          seen    = (Mailmate::IndexReader.for("#flags").flags_for(eml_id.to_i) rescue []).include?("\\Seen")
          "#{archive}#{seen ? 'R' : 'U'}"
        when "tags"
          flags = (Mailmate::IndexReader.for("#flags").flags_for(eml_id.to_i) rescue [])
          flags.reject { |f| f.start_with?("\\", "$") }.join(",")
        when "keywords"
          (Mailmate::IndexReader.for("#flags").flags_for(eml_id.to_i) rescue []).join(",")
        when "from"        then index_or_mail(eml_id, "from",        mail ? Array(mail.from).join("; ")     : nil)
        when "to"          then index_or_mail(eml_id, "to",          mail ? Array(mail.to).join("; ")       : nil)
        when "cc"          then index_or_mail(eml_id, "cc",          mail ? Array(mail.cc).join("; ")       : nil)
        when "bcc"         then index_or_mail(eml_id, "bcc",         mail ? Array(mail.bcc).join("; ")      : nil)
        when "reply-to"    then index_or_mail(eml_id, "reply-to",    mail ? Array(mail.reply_to).join("; ") : nil)
        when "subject"     then index_or_mail(eml_id, "subject",     mail&.subject)
        when "message-id"  then index_or_mail(eml_id, "message-id",  mail&.message_id)
        when "message-url"
          mid = index_or_mail(eml_id, "message-id", mail&.message_id)
          mid.empty? ? "" : Mailmate::MidUrl.message_url_for(mid)
        when "references"  then index_or_mail(eml_id, "references",  mail ? Array(mail.references).join(" ")  : nil)
        when "in-reply-to" then index_or_mail(eml_id, "in-reply-to", mail ? Array(mail.in_reply_to).join(" ") : nil)
        when "direction"   then outbound?(path, mail, eml_id) ? "→" : "←"
        when "party"       then party_for(eml_id, mail, outbound?(path, mail, eml_id))
        end.to_s
      end

      def fields_tier(fields)
        ts = fields.map { |f| FIELD_TIERS[f] || :header }.uniq
        return :full   if ts.include?(:full)
        return :header if ts.include?(:header)
        :index
      end

      # ---- driver loop --------------------------------------------------------

      def load_message(path, tier)
        case tier
        when :index then nil
        when :header
          bytes = +""
          File.open(path, "rb") do |f|
            while (chunk = f.read(4096))
              bytes << chunk
              idx = bytes.index("\r\n\r\n") || bytes.index("\n\n")
              break if idx
              break if bytes.bytesize > 65_536
            end
          end
          Mail.new(bytes)
        when :full
          Mail.read(path)
        end
      end

      def collect_rows(dirs:, specs:, fields:, smart_evaluator:, smart_literals:, filter_only_tier:, load_tier:, opts:)
        reset_run_caches!
        rows = []
        catch(:done) do
          dirs.each do |dir|
            Dir.each_child(dir) do |fname|
              next unless fname.end_with?(".eml")
              eml_id = fname.sub(".eml", "")
              path = "#{dir}/#{fname}"

              next unless prefilter_pass?(path, specs, smart_literals)

              if filter_only_tier == :index
                if smart_evaluator
                  next unless smart_evaluator.matches?(Mailmate::Message.new(nil, eml_id, path))
                end
                if !specs.empty?
                  next unless matches?(nil, eml_id, specs, opts[:headers_only], path,
                                       index_only: !opts[:all], exclude_quoted: opts[:exclude_quoted])
                end
              end

              mail = nil
              if load_tier != :index
                begin
                  mail = load_message(path, load_tier)
                rescue StandardError => e
                  warn "[skip] #{path}: #{e.message}"
                  next
                end
              end

              if filter_only_tier != :index
                if !specs.empty?
                  next unless matches?(mail, eml_id, specs, opts[:headers_only], path,
                                       index_only: !opts[:all], exclude_quoted: opts[:exclude_quoted])
                end
                if smart_evaluator
                  next unless smart_evaluator.matches?(Mailmate::Message.new(mail, eml_id, path))
                end
              end

              rows << fields.map { |f| extract(f, eml_id, path, mail) }
              throw :done if opts[:limit] && rows.size >= opts[:limit]
            end
          end
        end
        rows
      end

      # ---- output -------------------------------------------------------------

      def csv_quote(cell)
        cell = cell.to_s.gsub(/[\r\n]+/, " ")
        if cell.include?(",") || cell.include?("\"")
          "\"#{cell.gsub("\"", "\"\"")}\""
        else
          cell
        end
      end

      def emit_output(rows, fields, opts)
        header_row = fields.map { |f| HEADER_LABELS[f] || f }

        if opts[:align]
          display_rows = rows.map { |r| r.map { |c| csv_quote(c) } }
          display_rows.unshift(header_row) if opts[:header]
          widths = Array.new(fields.size, 0)
          display_rows.each do |r|
            r.each_with_index { |c, i| widths[i] = c.length if c.length > widths[i] }
          end
          display_rows.each do |r|
            padded = r.each_with_index.map do |c, i|
              i == r.size - 1 ? c : c.ljust(widths[i])
            end
            puts padded.join(",")
          end
        else
          puts CSV.generate_line(header_row) if opts[:header]
          rows.each { |r| puts CSV.generate_line(r) }
        end
      end
    end
  end
end
