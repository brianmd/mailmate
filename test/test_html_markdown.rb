# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/html_markdown"

# The shared HTML → markdown converter behind `mmmessage --markdown` and the
# quoted original of a reply/forward. Its whole job beyond reverse_markdown
# is surviving transactional/marketing mail built from layout tables.
class TestHtmlMarkdown < Minitest::Test
  def convert(html)
    Mailmate::HtmlMarkdown.convert(html)
  end

  def test_available_here
    assert Mailmate::HtmlMarkdown.available?, "reverse_markdown is a dev dependency; the suite needs it"
  end

  def test_plain_html_converts_to_markdown
    assert_equal "Hello **there**", convert("<p>Hello <b>there</b></p>")
  end

  def test_drops_head_style_script_and_comments
    md = convert("<html><head><title>Email Template</title><style>a{}</style></head>" \
                 "<body><!--[if mso]>x<![endif]--><script>1</script><p>Body</p></body></html>")
    assert_equal "Body", md
  end

  # The RubyGems push notice: nested layout tables, spacer cells, &nbsp;
  # padding. Every wrapper used to become `| |` / `| &nbsp; |` noise.
  def test_unwraps_nested_layout_tables_into_flowing_text
    html = <<~HTML
      <table cellpadding="0"><tr><td>
        <table><tr><td>&nbsp;</td></tr></table>
        <table><tr><td><img src="logo.png" alt="Logo"></td></tr>
               <tr><td>A gem you have push access to has recently released a new version.</td></tr></table>
        <table><tr><td>&nbsp;</td><td><a href="https://x">HOME</a> &nbsp;|&nbsp; <a href="https://y">GUIDES</a></td></tr></table>
      </td></tr></table>
    HTML
    md = convert(html)
    refute_includes md, "|\n"
    refute_includes md, "| |"
    refute_includes md, "&nbsp;"
    assert_includes md, "![Logo](logo.png)"
    assert_includes md, "A gem you have push access to has recently released a new version."
    assert_includes md, "[HOME](https://x)"
  end

  def test_keeps_a_real_data_table
    html = "<table><tr><th>Item</th><th>Price</th></tr><tr><td>Apple</td><td>$1</td></tr><tr><td>Pear</td><td>$2</td></tr></table>"
    md = convert(html)
    assert_includes md, "| Item | Price |"
    assert_includes md, "| Apple | $1 |"
  end

  def test_a_two_column_key_value_row_inside_layout_reads_as_one_line
    html = "<table><tr><td><img src='hero.jpg'></td></tr><tr><td>Amount:</td></tr></table>" \
           "<table><tr><td>Amount:</td><td><b>$22.08</b></td></tr></table>"
    md = convert(html)
    assert_includes md, "Amount: **$22.08**"
  end

  def test_nbsp_becomes_a_plain_space_not_an_entity
    md = convert("<p>HOME&nbsp;&nbsp;|&nbsp;&nbsp;BLOG</p>")
    refute_includes md, "&nbsp;"
    assert_includes md, "HOME | BLOG"
  end

  def test_zero_width_preview_padding_is_removed
    md = convert("<p>Hi​​͏ there</p>")
    assert_equal "Hi there", md
  end

  def test_hidden_elements_and_tracking_pixels_are_dropped
    html = "<div style=\"display:none; font-size:0\">PREHEADER TEXT</div>" \
           "<img src=\"https://t.example/open.gif\" width=\"1\" height=\"1\">" \
           "<p>Visible</p><img src=\"photo.jpg\" width=\"300\">"
    md = convert(html)
    refute_includes md, "PREHEADER"
    refute_includes md, "open.gif"
    assert_includes md, "Visible"
    assert_includes md, "photo.jpg"
  end

  def test_html5_sectioning_tags_are_dropped_but_their_content_kept
    md = convert("<header><p>Top</p></header><section><p>Middle</p></section><footer><span>We'll never ask for your PIN.</span></footer><center>C</center>")
    refute_includes md, "<footer>"
    refute_includes md, "<section>"
    refute_includes md, "<center>"
    assert_includes md, "We'll never ask for your PIN."
    assert_includes md, "Top"
    assert_includes md, "C"
  end

  def test_collapses_runs_of_blank_lines
    md = convert("<p>a</p><div></div><div></div><div></div><p>b</p>")
    refute_match(/\n{3,}/, md)
  end

  def test_convert_returns_nil_when_the_optional_gem_is_missing
    mod = Mailmate::HtmlMarkdown
    orig = mod.method(:available?)
    mod.define_singleton_method(:available?) { false }
    assert_nil convert("<p>x</p>")
  ensure
    mod.define_singleton_method(:available?, orig)
  end
end
