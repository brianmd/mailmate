# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestReplyPrefill < Minitest::Test
  include Mailmate::TestHelpers

  # Write `raw` as an .eml in a tmpdir and point EmlLookup at it for the
  # block, so the derivation can be tested without a live MailMate index.
  def with_parent(raw)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "42.eml")
      File.write(path, raw)
      lookup = Mailmate::EmlLookup
      orig_resolve = lookup.method(:resolve_id)
      orig_path = lookup.method(:path_for)
      lookup.define_singleton_method(:resolve_id) { |input| input.to_s == "missing" ? nil : 42 }
      lookup.define_singleton_method(:path_for) { |_id| path }
      begin
        yield
      ensure
        lookup.define_singleton_method(:resolve_id, orig_resolve)
        lookup.define_singleton_method(:path_for, orig_path)
      end
    end
  end

  def eml(headers: {}, body: "Original body.\nSecond line.")
    base = {
      "From" => "Parent Sender <parent@example.com>",
      "To" => "me@example.com",
      "Subject" => "Closet flickering",
      "Date" => "Tue, 11 Aug 2026 09:00:00 -0600",
      "Message-ID" => "<parent@example.com>"
    }.merge(headers)
    base.reject { |_, v| v.nil? }.map { |k, v| "#{k}: #{v}" }.join("\n") + "\n\n#{body}"
  end

  def build(mode: "reply", identities: ["me@example.com"], **kw)
    Mailmate::ReplyPrefill.build("42", mode: mode, identities: identities, **kw)
  end

  # --- Threading chain: the one rule everything else exists to protect -----

  def test_in_reply_to_is_the_parents_bracketed_message_id
    with_parent(eml) { assert_equal "<parent@example.com>", build.in_reply_to }
  end

  def test_references_appends_message_id_to_the_parents_own_chain
    with_parent(eml(headers: { "References" => "<root@example.com> <mid@example.com>" })) do
      assert_equal "<root@example.com> <mid@example.com> <parent@example.com>", build.references
    end
  end

  def test_references_is_the_bare_message_id_for_a_thread_root
    with_parent(eml) { assert_equal "<parent@example.com>", build.references }
  end

  def test_unbracketed_parent_message_id_is_bracketed
    with_parent(eml(headers: { "Message-ID" => "bare@example.com" })) do
      assert_equal "<bare@example.com>", build.in_reply_to
    end
  end

  # A parent Message-ID carrying CR/LF must not be able to end the header and
  # start another one when it is later injected via `--header`.
  def test_crlf_in_the_parent_message_id_cannot_smuggle_a_header
    with_parent(eml(headers: { "Message-ID" => "<evil@example.com>" })) do
      # Header folding means the raw file can't easily carry a bare CRLF, so
      # assert the sanitizer directly on the value the chain would carry.
      smuggled = Mailmate::HeaderValue.bracket_message_id("a@b\r\nBcc: attacker@example.com")
      refute_includes smuggled, "\n"
      refute_includes smuggled, "\r"
    end
  end

  # --- Recipients ----------------------------------------------------------

  def test_reply_goes_to_the_sender
    with_parent(eml) { assert_equal ["parent@example.com"], build.to }
  end

  def test_reply_prefers_reply_to_over_from
    with_parent(eml(headers: { "Reply-To" => "elsewhere@example.com" })) do
      assert_equal ["elsewhere@example.com"], build.to
    end
  end

  def test_reply_does_not_cc_anyone
    with_parent(eml(headers: { "Cc" => "other@example.com" })) { assert_empty build.cc }
  end

  def test_reply_all_ccs_the_others_minus_my_identities_and_the_to_address
    raw = eml(headers: { "To" => "me@example.com, third@example.com", "Cc" => "fourth@example.com" })
    with_parent(raw) do
      p = build(mode: "reply-all")
      assert_equal ["parent@example.com"], p.to
      assert_equal %w[third@example.com fourth@example.com], p.cc
    end
  end

  def test_from_is_the_identity_the_parent_was_addressed_to
    raw = eml(headers: { "To" => "other@example.com", "Cc" => "alt@example.com" })
    with_parent(raw) do
      assert_equal "alt@example.com", build(identities: %w[me@example.com alt@example.com]).from
    end
  end

  def test_from_is_nil_when_no_identity_matches_so_the_caller_decides
    with_parent(eml(headers: { "To" => "someone@example.com" })) do
      assert_nil build(identities: ["me@example.com"]).from
    end
  end

  # --- Subject -------------------------------------------------------------

  def test_subject_gets_a_re_prefix
    with_parent(eml) { assert_equal "Re: Closet flickering", build.subject }
  end

  def test_subject_is_not_double_prefixed
    with_parent(eml(headers: { "Subject" => "Re: Closet flickering" })) do
      assert_equal "Re: Closet flickering", build.subject
    end
  end

  def test_existing_prefix_variants_are_left_alone
    with_parent(eml(headers: { "Subject" => "Re[2]: Closet flickering" })) do
      assert_equal "Re[2]: Closet flickering", build.subject
    end
  end

  # --- Quoted body ---------------------------------------------------------

  def test_quoted_body_is_attributed_and_prefixed
    with_parent(eml) do
      q = build.quoted_body
      assert_includes q, "wrote:"
      assert_includes q, "> Original body."
      assert_includes q, "> Second line."
    end
  end

  HTML_ONLY = "From: parent@example.com\nSubject: Hi\nMessage-ID: <p@example.com>\n" \
              "Content-Type: text/html\n\n<p>Hello <b>there</b></p>"

  # Both alternatives present: the html says one thing, the plain another,
  # so a test can tell which one was quoted.
  ALTERNATIVE = "From: parent@example.com\nSubject: Hi\nMessage-ID: <p@example.com>\n" \
                "Content-Type: multipart/alternative; boundary=\"b1\"\n\n" \
                "--b1\nContent-Type: text/plain\n\nPLAIN VERSION\n" \
                "--b1\nContent-Type: text/html\n\n<p><b>HTML</b> VERSION</p>\n--b1--\n"

  # Simulate the optional reverse_markdown gem being absent.
  def without_converter
    mod = Mailmate::HtmlMarkdown
    orig = mod.method(:convert)
    mod.define_singleton_method(:convert) { |_html| nil }
    yield
  ensure
    mod.define_singleton_method(:convert, orig)
  end

  def test_html_only_parent_is_quoted_as_markdown_in_a_reply_never_as_raw_html
    with_parent(HTML_ONLY) do
      q = build.quoted_body
      assert_includes q, "> Hello **there**"
      refute_includes q, "<b>"
    end
  end

  def test_reply_prefers_the_html_part_rendered_to_markdown_when_both_alternatives_exist
    with_parent(ALTERNATIVE) do
      q = build.quoted_body
      assert_includes q, "> **HTML** VERSION"
      refute_includes q, "PLAIN VERSION"
    end
  end

  def test_reply_falls_back_to_the_plain_part_when_the_converter_is_missing
    with_parent(ALTERNATIVE) do
      without_converter do
        q = build.quoted_body
        assert_includes q, "> PLAIN VERSION"
        refute_includes q, "HTML"
      end
    end
  end

  def test_html_only_reply_yields_an_honest_placeholder_when_the_converter_is_missing
    with_parent(HTML_ONLY) do
      without_converter do
        q = build.quoted_body
        assert_includes q, "[no plain-text alternative"
        refute_includes q, "<b>"
      end
    end
  end

  # --- Forward -------------------------------------------------------------

  def test_forward_does_not_thread
    with_parent(eml(headers: { "References" => "<root@example.com>" })) do
      p = build(mode: "forward")
      assert_nil p.in_reply_to
      assert_nil p.references
    end
  end

  def test_forward_has_no_recipients_and_a_fwd_subject
    with_parent(eml) do
      p = build(mode: "forward")
      assert_empty p.to
      assert_equal "Fwd: Closet flickering", p.subject
    end
  end

  # The bug that prompted this: a bank alert (HTML-only) forwarded from the
  # markdownr popup carried the header block and nothing else. A forward's
  # recipient has never seen the message, so the body must come from
  # whatever part exists — and it should read as the author laid it out.
  def test_forward_of_an_html_only_parent_carries_the_body_as_markdown
    with_parent(HTML_ONLY) do
      q = build(mode: "forward").quoted_body
      assert_includes q, "---------- Forwarded message ----------"
      assert_includes q, "Hello **there**"
      refute_includes q, "<b>"
      refute_includes q, "> Hello"
    end
  end

  def test_forward_prefers_the_html_part_over_the_plain_alternative
    with_parent(ALTERNATIVE) do
      q = build(mode: "forward").quoted_body
      assert_includes q, "**HTML** VERSION"
      refute_includes q, "PLAIN VERSION"
    end
  end

  def test_forward_falls_back_to_the_plain_part_when_the_converter_is_missing
    with_parent(ALTERNATIVE) do
      without_converter do
        q = build(mode: "forward").quoted_body
        assert_includes q, "PLAIN VERSION"
        refute_includes q, "HTML"
      end
    end
  end

  def test_forward_of_an_html_only_parent_is_never_silently_empty
    with_parent(HTML_ONLY) do
      without_converter do
        q = build(mode: "forward").quoted_body
        assert_includes q, "[the original has no readable text"
        refute_includes q, "<b>"
      end
    end
  end

  def test_forward_drops_style_blocks_and_comments_and_transcodes_the_declared_charset
    raw = "From: parent@example.com\nSubject: Hi\nMessage-ID: <p@example.com>\n" \
          "Content-Type: text/html; charset=iso-8859-1\nContent-Transfer-Encoding: 8bit\n\n" \
          "<html><head><style>body{margin:0}</style></head><body><!-- tdMobZ1 --><p>Caf\xE9 <a href=\"https://x.example\">link</a></p></body></html>"
    with_parent(raw.b) do
      q = build(mode: "forward").quoted_body
      assert_includes q, "Café"
      assert_includes q, "[link](https://x.example)"
      refute_includes q, "margin:0"
      refute_includes q, "tdMobZ1"
    end
  end

  def test_forward_body_is_an_unprefixed_block_with_its_own_header_summary
    with_parent(eml) do
      q = build(mode: "forward").quoted_body
      assert_includes q, "---------- Forwarded message ----------"
      assert_includes q, "Subject: Closet flickering"
      assert_includes q, "Original body."
      refute_includes q, "> Original body."
    end
  end

  # --- Errors --------------------------------------------------------------

  def test_unresolvable_id_raises_not_found
    with_parent(eml) do
      assert_raises(Mailmate::ReplyPrefill::NotFound) { Mailmate::ReplyPrefill.build("missing") }
    end
  end

  def test_unknown_mode_raises
    with_parent(eml) { assert_raises(ArgumentError) { build(mode: "bounce") } }
  end
end
