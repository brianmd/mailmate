# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # HTML → clean markdown, shared by `mmmessage --markdown` (terminal reading)
  # and ReplyPrefill (quoting an HTML-only parent in a forward or reply).
  #
  # Depends on reverse_markdown (which pulls nokogiri), an OPTIONAL dependency
  # so the base install stays free of native extensions. `available?` says
  # whether the converter can run; `convert` returns nil when it can't, and
  # each caller decides what an honest fallback looks like for its surface —
  # mmmessage prints the raw HTML with a hint, a prefill uses a placeholder.
  #
  # Three passes beyond plain reverse_markdown, all learned from newsletters:
  #   1. Drop <style> / <script> blocks and HTML comments before conversion —
  #      pure clutter that reverse_markdown otherwise dumps as inline text.
  #   2. Strip zero-width spacers used to control inbox preview text (U+034F,
  #      U+200B/C/D, U+FEFF) and turn non-breaking spaces into plain ones, or
  #      the output carries long runs of `͏ `.
  #   3. Trim trailing whitespace per line and collapse 3+ blank lines to one.
  module HtmlMarkdown
    extend self

    def available?
      require "nokogiri"
      require "reverse_markdown"
      true
    rescue LoadError
      false
    end

    # Markdown String, or nil when the optional gems are missing.
    def convert(html)
      return nil unless available?

      doc = Nokogiri::HTML(html.to_s)
      doc.css("style, script").remove
      # Comments too: newsletter templates leave `<!-- tdMobZ1BottomNew-->`
      # markers that reverse_markdown would otherwise print verbatim.
      doc.xpath("//comment()").remove
      md = ReverseMarkdown.convert(doc.to_html)
      # U+034F combining grapheme joiner, U+200B ZWSP, U+200C ZWNJ,
      # U+200D ZWJ, U+FEFF BOM/ZWNBSP — newsletter preview-text padding.
      md.gsub!(/[\u034F\u200B\u200C\u200D\uFEFF]/, "")
      # Non-breaking spaces (and their Unicode cousins) → plain spaces so the
      # per-line rstrip below can collapse the padding they hold open.
      md.gsub!(/[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/, " ")
      md = md.lines.map(&:rstrip).join("\n")
      md.gsub!(/\n{3,}/, "\n\n")
      md.strip
    end
  end
end
