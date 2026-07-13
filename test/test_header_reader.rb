# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestHeaderReader < Minitest::Test
  include Mailmate::TestHelpers

  EXAMPLE_EML = <<~EML.freeze
    From: Sender <sender@example.com>
    To: recipient@example.com
    Subject: Test message
    Message-ID: <abc123@example.com>
    Date: Mon, 11 May 2026 12:00:00 +0000
    Content-Type: text/plain

    This is the body of the message.
    It should not appear in any header lookups.
  EML

  def with_eml(content = EXAMPLE_EML)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.eml")
      File.binwrite(path, content)
      yield path
    end
  end

  def test_reads_named_header
    with_eml do |path|
      assert_equal "recipient@example.com", Mailmate::HeaderReader.header(path, "To")
      assert_equal "Test message", Mailmate::HeaderReader.header(path, "Subject")
    end
  end

  def test_header_lookup_is_case_insensitive
    with_eml do |path|
      assert_equal "recipient@example.com", Mailmate::HeaderReader.header(path, "to")
      assert_equal "Test message", Mailmate::HeaderReader.header(path, "SUBJECT")
    end
  end

  def test_missing_header_returns_nil
    with_eml do |path|
      assert_nil Mailmate::HeaderReader.header(path, "X-Nonexistent")
    end
  end

  def test_message_id_strips_angle_brackets
    with_eml do |path|
      assert_equal "abc123@example.com", Mailmate::HeaderReader.message_id(path)
    end
  end

  def test_message_id_returns_nil_when_absent
    no_mid = EXAMPLE_EML.sub(/^Message-ID:.*\n/, "")
    with_eml(no_mid) do |path|
      assert_nil Mailmate::HeaderReader.message_id(path)
    end
  end

  def test_does_not_match_body_content
    body_with_header_lookalike = <<~EML
      From: real@example.com
      Subject: Hi

      To: this-is-in-the-body@example.com
    EML
    with_eml(body_with_header_lookalike) do |path|
      assert_nil Mailmate::HeaderReader.header(path, "To"),
                 "Should not match 'To:' lines that appear in the body"
    end
  end

  def test_handles_crlf_line_endings
    crlf = EXAMPLE_EML.gsub("\n", "\r\n")
    with_eml(crlf) do |path|
      assert_equal "recipient@example.com", Mailmate::HeaderReader.header(path, "To")
    end
  end

  def test_unfolds_folded_subject_per_rfc_5322
    folded = <<~EML
      From: sender@example.com
      Subject: This is a really long subject line that the
        sending mail client decided to fold across
       multiple lines
      Date: Mon, 11 May 2026 12:00:00 +0000

      Body content here.
    EML
    with_eml(folded) do |path|
      val = Mailmate::HeaderReader.header(path, "Subject")
      assert_equal "This is a really long subject line that the sending mail client decided to fold across multiple lines", val
    end
  end

  def test_unfolds_folded_to_header_with_multiple_recipients
    folded = <<~EML
      From: sender@example.com
      To: alice@example.com,
       bob@example.com,
       carol@example.com
      Subject: hi

      body
    EML
    with_eml(folded) do |path|
      val = Mailmate::HeaderReader.header(path, "To")
      assert_equal "alice@example.com, bob@example.com, carol@example.com", val
    end
  end

  def test_unfold_helper_collapses_crlf_wsp_runs
    raw = "line one\r\n  line two\r\n\tline three"
    assert_equal "line one line two line three", Mailmate::HeaderReader.unfold(raw)
  end

  def test_max_bytes_caps_reading
    # Build a file with the header buried past the cap; reader should not find it.
    padded = ("X-Padding: #{"a" * 100}\n" * 800) + EXAMPLE_EML
    with_eml(padded) do |path|
      # First headers within max_bytes should still resolve…
      refute_nil Mailmate::HeaderReader.header(path, "X-Padding")
      # …but headers past the cap (well past 64KB of padding) won't.
      # Actual header position: ~80KB in. Default cap is 65_536. So nope.
      assert_nil Mailmate::HeaderReader.header(path, "Subject")
    end
  end
end
