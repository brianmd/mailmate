# frozen_string_literal: true

module Mailmate
  # @api public
  #
  # HTML → clean markdown, shared by `mmmessage --markdown` (terminal reading)
  # and ReplyPrefill (quoting an HTML parent in a forward or reply).
  #
  # Depends on reverse_markdown (which pulls nokogiri), an OPTIONAL dependency
  # so the base install stays free of native extensions. `available?` says
  # whether the converter can run; `convert` returns nil when it can't, and
  # each caller decides what an honest fallback looks like for its surface —
  # mmmessage prints the raw HTML with a hint, a prefill uses a placeholder.
  #
  # reverse_markdown alone is fine for hand-written HTML and hopeless for
  # transactional/marketing mail, which is built from nested LAYOUT tables:
  # every wrapper becomes a pipe-table fragment (`| |`, `| &nbsp; |`) and the
  # message reads as noise (RubyGems' push notice, 2026-09-04). So the DOM is
  # cleaned before conversion:
  #   1. Drop <head>, <style>, <script> and HTML comments (MSO conditionals,
  #      template markers like `<!-- tdMobZ1BottomNew-->`).
  #   2. Drop elements hidden inline (`display:none` — preheaders, mobile-only
  #      duplicates) and tracking/spacer images (declared ≤ 2px).
  #   3. Unwrap LAYOUT tables into flowing blocks (rows → div, cells → span),
  #      keeping DATA tables (a regular grid of short inline cells, ≥ 2 rows ×
  #      ≥ 2 columns, no nested tables) as markdown tables. Innermost first.
  #   4. Normalize the text itself: zero-width spacers used for inbox preview
  #      padding (U+034F, U+200B/C/D, U+FEFF) removed, non-breaking spaces
  #      made ordinary — in the DOM, so reverse_markdown never sees a U+00A0
  #      to spell as `&nbsp;`.
  #   5. Convert with unknown tags BYPASSED (content kept, tag dropped) —
  #      reverse_markdown would otherwise print <footer>/<section>/<center>
  #      verbatim — then trim trailing whitespace per line and collapse 3+
  #      blank lines to one.
  module HtmlMarkdown
    extend self

    ZERO_WIDTH = /[͏​‌‍﻿]/
    NBSP_LIKE  = /[   -   　]/
    BLOCKISH   = "img, div, p, table, ul, ol, h1, h2, h3, h4, h5, h6, br, blockquote, pre"

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
      clean!(doc)
      # unknown_tags: :bypass — reverse_markdown's default PASSES THROUGH tags it
      # doesn't know, and it doesn't know HTML5 sectioning (<footer>, <header>,
      # <section>, <center>…), so a bank alert's footer arrived as raw markup.
      # Bypass keeps the content and drops the tag.
      md = ReverseMarkdown.convert(doc.to_html, unknown_tags: :bypass)
      md = md.lines.map(&:rstrip).join("\n")
      md.gsub!(/\n{3,}/, "\n\n")
      md.strip
    end

    # The DOM passes, in order. Public so a caller can inspect the cleaned
    # HTML; `convert` is what everyone actually wants.
    def clean!(doc)
      doc.css("head, style, script").remove
      doc.xpath("//comment()").remove
      doc.css("[style]").each { |n| n.remove if n["style"].to_s.match?(/display\s*:\s*none/i) }
      doc.css("img").each { |img| img.remove if spacer_image?(img) }
      unwrap_layout_tables!(doc)
      doc.xpath("//text()").each do |t|
        s = t.content
        cleaned = s.gsub(ZERO_WIDTH, "").gsub(NBSP_LIKE, " ")
        t.content = cleaned if cleaned != s
      end
      doc
    end

    private

    def spacer_image?(img)
      %w[width height].any? do |attr|
        v = img[attr].to_s.strip
        v.match?(/\A\d+(px)?\z/) && v.to_i <= 2
      end
    end

    # Innermost first, so a data table nested in a layout wrapper is judged
    # on its own shape before the wrapper around it is dissolved.
    def unwrap_layout_tables!(doc)
      tables = doc.css("table").to_a
      tables.sort_by { |t| -t.ancestors("table").size }.each do |t|
        next if data_table?(t)

        t.css("td, th").each do |c|
          c.name = "span"
          c.add_next_sibling(Nokogiri::XML::Text.new(" ", doc))
        end
        t.css("tr").each { |r| r.name = "div" }
        t.css("thead, tbody, tfoot, caption, colgroup").each { |n| n.name = "div" }
        t.name = "div"
        t.attributes.each_key { |k| t.remove_attribute(k) }
      end
    end

    # A table we keep as a table: at least two rows with the same cell count
    # (≥ 2), no table inside it, and only short inline content in its cells.
    # Everything else — single-column stacks, image frames, spacer rows,
    # anything nesting another table — is layout.
    def data_table?(table)
      return false if table.at_css("table")

      rows = table.xpath("./tr|./thead/tr|./tbody/tr|./tfoot/tr")
      return false if rows.size < 2

      counts = rows.map { |r| r.xpath("./td|./th").size }
      return false unless counts.uniq.size == 1 && counts.first >= 2

      cells = rows.flat_map { |r| r.xpath("./td|./th").to_a }
      cells.none? { |c| c.at_css(BLOCKISH) || c.text.strip.length > 200 }
    end
  end
end
