# frozen_string_literal: true

require "set"
require_relative "attributes"
require_relative "source_resolver"
require_relative "message"

# @api private
#
# VarResolver — resolves `$VAR.attr` references in smart-mailbox filters.
#
# Semantics: `LHS = $VAR.attr` means "LHS equals SOME value of `attr` taken
# over all messages in mailbox VAR". The set is built once per (var, attr)
# pair and cached for the lifetime of the resolver.
#
# Variable lookup: `$VAR` → mailbox UUID, with fallback to name lookup.
# `$SENT` → SENT (special UUID); `$PERSONAL_INBOX` → PERSONAL_INBOX (UUID
# of a smart mailbox in MailMate's defaults).
#
# Cycle detection: if `$A` resolves through the graph to a filter that
# references `$A`, raise. (None of Brian's current filters cycle.)

module Mailmate
  class VarResolver
    class CycleError < StandardError; end
    class UnsupportedVar < StandardError; end

    def initialize(graph)
      @graph = graph
      @source_resolver = SourceResolver.new(graph)
      @cache    = {}
      @visiting = []
    end

    # Returns an Array<String|AddressValue|...> of values seen for `attr_path`
    # in the mailbox named `var_name`. Empty array if no matches.
    def resolve(var_name, attr_path)
      key = [var_name, attr_path]
      return @cache[key] if @cache.key?(key)

      raise CycleError, "var-resolution cycle: #{(@visiting + [var_name]).join(" → ")}" \
        if @visiting.include?(var_name)
      @visiting << var_name

      begin
        # 1. Resolve the variable's mailbox to dirs + smart-filter chain.
        uuid = MailboxGraph::SPECIAL_UUIDS.include?(var_name) ? var_name : @graph.by_name[var_name]
        raise UnsupportedVar, "Unknown mailbox referenced: $#{var_name}" unless uuid

        res = @source_resolver.resolve(uuid)
        dirs = res[:dirs]
        filter_str = compose_filter(res[:filters])

        # 2. Build a child evaluator if there's an inner filter, with the
        # *same* var resolver so nested $vars resolve.
        inner_eval = filter_str ? Evaluator.new(Mailmate.compile_filter(filter_str), var_resolver: self) : nil

        # 3. Walk dirs, collect attr_path values from matching messages.
        values = []
        dirs.each do |dir|
          Dir.each_child(dir) do |fname|
            next unless fname.end_with?(".eml")
            path = "#{dir}/#{fname}"
            eml_id = fname.sub(".eml", "").to_i
            begin
              # Header-only parse: most $var attrs are headers, and a full
              # Mail.read on each Sent message would be slow.
              mail = Mail.new(read_header_block(path))
            rescue StandardError
              next
            end
            msg = Message.new(mail, eml_id, path)
            next if inner_eval && !inner_eval.matches?(msg)

            v = Attributes.resolve(msg, attr_path)
            Array(v).each { |x| values << x.to_s if x }
          end
        end

        @cache[key] = values
      ensure
        @visiting.pop
      end
    end

    private

    def compose_filter(filters)
      return nil if filters.empty?
      filters.size == 1 ? filters.first : "(#{filters.map { |f| "(#{f})" }.join(" and ")})"
    end

    # Header-only read: stop at the first blank line (capped at 64KB).
    # Same primitive used by the raw-bytes pre-filter in mailmate-search.
    def read_header_block(path)
      bytes = +""
      File.open(path, "rb") do |f|
        while (chunk = f.read(4096))
          bytes << chunk
          idx = bytes.index("\r\n\r\n") || bytes.index("\n\n")
          return bytes[0..idx] if idx
          break if bytes.bytesize > 65_536
        end
      end
      bytes
    end
  end
end
