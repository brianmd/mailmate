# frozen_string_literal: true

require_relative "ast"

# @api private
#
# FilterClassifier — walks an AST and answers questions about what's
# required to evaluate it. Used by `mailmate-search` to pick the cheapest
# `.eml` loading tier per query:
#
#   :index   — every path is index-backed; never open the .eml at all.
#   :header  — every path resolves from headers (or index); read header block only.
#   :full    — at least one path needs body content; full Mail.read.
#
# Also extracts ASCII string literals from top-level AND-chained
# header-path comparisons so the raw-bytes pre-filter can short-circuit
# without parsing.

module Mailmate
  module FilterClassifier
    # Heads served by an on-disk index in Database.noindex/Headers/<name>.
    INDEX_BACKED_HEADS = %w[
      #flags ##tags
      #date #date-received #date-sent #date-last-viewed
    ].freeze

    # Heads that resolve from .eml header bytes (vs. body).
    HEADER_HEADS = %w[
      from to cc bcc reply-to sender resent-from resent-to resent-cc resent-bcc
      subject list-id message-id in-reply-to references
      x-mailer user-agent x-newsreader received delivered-to
      #recipient #any-address #mailer ##thread-id
    ].freeze

    # Heads that require the body to resolve.
    BODY_HEADS = %w[#unquoted #quoted #common #commonplus].freeze

    # Heads whose literals appear textually in the .eml header bytes
    # (so they're safe pre-filter candidates).
    PREFILTER_HEADS = %w[
      from to cc bcc reply-to sender
      subject list-id message-id in-reply-to references
      x-mailer user-agent x-newsreader
      #recipient #any-address #mailer
    ].freeze

    # Returns one of :index, :header, :full.
    def self.tier(ast)
      heads = collect_path_heads(ast)
      return :full   if heads.any? { |h| BODY_HEADS.include?(h) }
      return :index  if heads.all? { |h| INDEX_BACKED_HEADS.include?(h) }
      :header
    end

    # Same idea but for a list of attribute paths (e.g. fields the user wants
    # output, or paths the user-search specs reference).
    def self.tier_for_paths(paths)
      heads = paths.map { |p| Array(p).first }.compact
      return :full   if heads.any? { |h| BODY_HEADS.include?(h) }
      return :index  if !heads.empty? && heads.all? { |h| INDEX_BACKED_HEADS.include?(h) }
      :header
    end

    # Combine multiple tiers; the strictest wins. (full > header > index)
    def self.combine_tiers(*tiers)
      return :full   if tiers.include?(:full)
      return :header if tiers.include?(:header)
      :index
    end

    # ASCII literals from top-level AND-chained header-path comparisons,
    # which are guaranteed to appear (substring-wise) in any matching message's
    # raw header bytes. Skips OR branches (literals there are alternatives,
    # not requirements) and skips negated comparisons.
    def self.header_literals(ast)
      walk_top_and(ast).flat_map { |node| literal_from(node) }.compact.uniq
    end

    # ---- internals ----

    def self.collect_path_heads(ast)
      heads = []
      walk(ast) do |n|
        case n
        when AST::CompareNode, AST::ExistsNode
          heads << n.path[0]
        when AST::VarRefNode
          # var refs are evaluated by walking the referenced mailbox,
          # which is its own search. The OUTER caller doesn't need to load
          # body for a var ref — only headers/index, depending on the
          # path's head on the LHS side. The inner mailbox walk classifies
          # itself when it runs (via VarResolver's own header-only scan).
        end
      end
      heads
    end

    def self.walk(ast, &blk)
      yield ast
      case ast
      when AST::AndNode, AST::OrNode then ast.children.each { |c| walk(c, &blk) }
      when AST::NotNode then walk(ast.child, &blk)
      end
    end

    def self.walk_top_and(ast)
      case ast
      when AST::AndNode then ast.children.flat_map { |c| walk_top_and(c) }
      else [ast]
      end
    end

    def self.literal_from(node)
      return [] unless node.is_a?(AST::CompareNode)
      return [] if %w[!= !~].include?(node.op)
      return [] unless PREFILTER_HEADS.include?(node.path[0])
      return [] unless node.value.is_a?(AST::LiteralStringNode)
      s = node.value.value
      return [] unless s.bytesize >= 3 && s.ascii_only?
      [s.downcase]
    end
  end
end
