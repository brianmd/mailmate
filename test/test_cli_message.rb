# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/message"
require "mail"
require "stringio"
require "tmpdir"

# Tests for Mailmate::CLI::Message — parse_options, text_body, usage_error.
# The `run` flow depends on EmlLookup hitting a live MailMate; we test that
# usage_error paths return non-zero exit codes.
class TestCliMessage < Minitest::Test
  include Mailmate::TestHelpers

  M = Mailmate::CLI::Message

  # ---- parse_options ----

  def test_parse_options_defaults
    refute M.parse_options([])[:raw]
    refute M.parse_options([])[:text_only]
  end

  def test_parse_options_raw
    assert M.parse_options(["--raw"])[:raw]
  end

  def test_parse_options_text_only
    assert M.parse_options(["--text-only"])[:text_only]
  end

  def test_parse_options_leaves_positional
    argv = ["--raw", "1234"]
    M.parse_options(argv)
    assert_equal ["1234"], argv
  end

  # ---- usage_error ----

  def test_usage_error_returns_2
    capture_warn { assert_equal 2, M.usage_error("test") }
  end

  # ---- text_body ----

  def test_text_body_uses_text_part_when_present
    mail = Mail.new do
      from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822
      text_part { body "Hello plain" }
      html_part { body "<p>Hello html</p>" }
    end
    assert_equal "Hello plain", M.text_body(mail).strip
  end

  def test_text_body_falls_back_to_html_with_note
    mail = Mail.new do
      from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822
      html_part { body "<p>Hello html</p>" }
    end
    body = M.text_body(mail)
    assert_match(/no text\/plain/, body)
    assert_match(/Hello html/, body)
  end

  def test_text_body_plain_when_no_parts
    mail = Mail.new do
      from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822
      body "Just plain content"
    end
    assert_match(/Just plain content/, M.text_body(mail))
  end

  # ---- text_body --markdown ----

  def test_text_body_markdown_is_noop_for_plain_text
    # text/plain bodies pass straight through — markdown flag must not alter them.
    mail = Mail.new do
      from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822
      text_part { body "Hello plain" }
      html_part { body "<p>Hello html</p>" }
    end
    assert_equal "Hello plain", M.text_body(mail, markdown: true).strip
  end

  def test_text_body_markdown_converts_html_part_to_markdown
    mail = Mail.new do
      from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822
      html_part { body "<h1>Title</h1><p>Body with a <a href='https://x.test'>link</a>.</p>" }
    end
    md = M.text_body(mail, markdown: true)
    refute_match(/<h1>|<p>|<a href/, md, "HTML tags must be gone after markdown render")
    assert_match(/Title/,  md)
    assert_match(/\[link\]\(https:\/\/x\.test\)/, md, "links should be preserved in markdown form")
    refute_match(/no text\/plain/, md, "the raw-HTML apology line must not appear when rendering markdown")
  end

  def test_text_body_markdown_strips_style_and_script_blocks
    mail = Mail.new do
      from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822
      html_part { body "<style>.x { color: red; }</style><script>alert('hi')</script><p>Real text</p>" }
    end
    md = M.text_body(mail, markdown: true)
    refute_match(/color:\s*red/,  md, "CSS from <style> must not leak through")
    refute_match(/alert\(/,       md, "JS from <script> must not leak through")
    assert_match(/Real text/,     md)
  end

  def test_text_body_markdown_handles_single_part_html
    # The 185537 case: no text_part, no html_part (multipart=false), content-type
    # is text/html. Used to dump raw HTML; with --markdown should render.
    raw = "From: a@b\r\nTo: c@d\r\nSubject: x\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body><p>Single-part HTML body</p></body></html>\r\n"
    mail = Mail.new(raw)
    md = M.text_body(mail, markdown: true)
    refute_match(/<p>|<body>|<html>/, md)
    assert_match(/Single-part HTML body/, md)
  end

  def test_text_body_markdown_strips_unicode_whitespace_padding
    # Newsletter preview-text padding: alternating nbsp/figure-space/regular space.
    padded = "Headline       "
    mail = Mail.new do
      from "a@b"; to "c@d"; subject "x"; date Time.now.rfc2822
      html_part { body "<p>#{padded}</p>" }
    end
    md = M.text_body(mail, markdown: true)
    first_line = md.lines.first.to_s
    assert_match(/Headline/, first_line)
    refute_match(/Headline\s{2,}\z/, first_line.rstrip + " ",
      "trailing whitespace must be stripped (no Unicode-space runs surviving)")
  end

  # ---- run: missing eml-id ----

  def test_run_missing_eml_id_returns_2
    code = capture_warn { M.run([]) }
    # capture_warn returns the captured stderr; we need to run and get the int.
    # Re-run to get the code:
    code = nil
    capture_warn { code = M.run([]) }
    assert_equal 2, code
  end

  def test_run_unresolvable_id_returns_1
    # A non-digit input is now treated as a candidate Message-ID; resolve_id
    # walks the message-id index and returns nil if no match. mmmessage then
    # reports "Not found" (exit 1), distinct from the missing-argument usage
    # error (exit 2).
    Dir.mktmpdir do |dir|
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        code = nil
        capture_warn { code = M.run(["abc"]) }
        assert_equal 1, code
      end
    end
  end

  # ---- run: --raw output ----

  def test_run_raw_writes_eml_bytes
    Dir.mktmpdir do |dir|
      inbox = File.join(dir, "Messages.noindex", "IMAP", "acct.imap", "INBOX.mailbox", "Messages")
      FileUtils.mkdir_p(inbox)
      eml_bytes = "From: a@b\nSubject: x\n\nBody\n"
      File.binwrite(File.join(inbox, "1.eml"), eml_bytes)
      headers = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers)
      # Minimal #source index: eml_id=1, range [0,len) → the on-disk URL.
      url = "imap://acct.imap/INBOX"
      File.binwrite(File.join(headers, "#source.cache"), url)
      File.binwrite(File.join(headers, "#source.offsets"), [1, 0, url.bytesize].pack("V3"))

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        out, code = capture_stdout_with_code { M.run(["--raw", "1"]) }
        assert_equal 0, code
        assert_equal eml_bytes, out
      end
    end
  end

  # ---- user_tags ----

  def test_user_tags_drops_system_flags
    with_flags_index(eml_id: 42, flags: "\\Seen $Forwarded processed rent") do
      assert_equal %w[processed rent], M.user_tags(42)
    end
  end

  def test_user_tags_empty_when_only_system_flags
    with_flags_index(eml_id: 42, flags: "\\Seen \\Flagged") do
      assert_equal [], M.user_tags(42)
    end
  end

  def test_user_tags_empty_for_nil_eml_id
    assert_equal [], M.user_tags(nil)
  end

  private

  def with_flags_index(eml_id:, flags:)
    Dir.mktmpdir do |dir|
      headers = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers)
      File.binwrite(File.join(headers, "#flags.cache"), flags)
      File.binwrite(File.join(headers, "#flags.offsets"), [eml_id, 0, flags.bytesize].pack("V3"))
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        yield
      end
    end
  end

  def capture_warn
    orig = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = orig
  end

  def capture_stdout_with_code
    orig = $stdout
    $stdout = StringIO.new
    $stdout.binmode
    code = yield
    [$stdout.string, code]
  ensure
    $stdout = orig
  end
end
