# frozen_string_literal: true

require_relative "test_helper"
require "mail"

# Direct tests for Mailmate::Attributes.resolve — covers each key in the
# SHORTHANDS table, every branch of head_values_from_mail, and every step
# decomposition (AddressValue / String / Time).
class TestAttributes < Minitest::Test
  include Mailmate::TestHelpers

  Attr = Mailmate::Attributes

  # ---- builders ----

  def single
    Mail.new do
      from    "Alice Example <alice@example.com>"
      to      "bob@example.org"
      subject "Hello"
      date    Time.utc(2026, 3, 15, 12, 0, 0).rfc2822
      body    "Body"
    end
  end

  def multi_recipient
    mail = Mail.new do
      from    "alice@example.com"
      to      ["bob@example.org", "Carol <carol@example.net>"]
      cc      "dan@example.io"
      bcc     "eve@example.co"
      subject "Re: [Tag] Multi"
      date    Time.utc(2026, 1, 2, 3, 4, 5).rfc2822
    end
    mail["Reply-To"]   = "alice-replies@example.com"
    mail["X-Mailer"]   = "TestMailer/1.0"
    mail["In-Reply-To"]= "<parent@example.com>"
    mail["References"] = "<root@example.com> <middle@example.com>"
    mail
  end

  def listy
    mail = Mail.new do
      from    "list@medium.com"
      subject "Daily digest"
      date    Time.utc(2026, 6, 1).rfc2822
    end
    mail["List-Id"] = "\"Medium Daily\" <medium.com>"
    mail
  end

  # ---- single-value head resolution ----

  def test_from_single_address_string
    v = Attr.resolve(single, ["from"])
    assert_kind_of Attr::AddressValue, v
    assert_equal "alice@example.com", v.address
    assert_equal "Alice Example", v.name
  end

  def test_to_single
    v = Attr.resolve(single, ["to"])
    assert_kind_of Attr::AddressValue, v
    assert_equal "bob@example.org", v.address
  end

  def test_subject_returns_string
    assert_equal "Hello", Attr.resolve(single, ["subject"])
  end

  def test_message_id_present
    mail = single
    mail.message_id = "abc@example.com"
    assert_equal "abc@example.com", Attr.resolve(mail, ["message-id"])
  end

  def test_unknown_header_falls_through
    mail = single
    mail["X-Custom"] = "foo"
    assert_equal "foo", Attr.resolve(mail, ["x-custom"])
  end

  def test_missing_header_returns_nil
    assert_nil Attr.resolve(single, ["x-not-set"])
  end

  # ---- multi-value head resolution ----

  def test_to_multi_returns_array
    v = Attr.resolve(multi_recipient, ["to"])
    assert_kind_of Array, v
    assert_equal 2, v.size
    assert_equal %w[bob@example.org carol@example.net].sort, v.map(&:address).sort
  end

  def test_cc_and_bcc
    cc = Attr.resolve(multi_recipient, ["cc"])
    bcc = Attr.resolve(multi_recipient, ["bcc"])
    assert_equal "dan@example.io", cc.address
    assert_equal "eve@example.co", bcc.address
  end

  def test_reply_to
    v = Attr.resolve(multi_recipient, ["reply-to"])
    assert_equal "alice-replies@example.com", v.address
  end

  # ---- SHORTHANDS ----

  def test_recipient_shorthand_collects_to_cc_bcc
    addrs = Array(Attr.resolve(multi_recipient, ["#recipient"])).map(&:address).sort
    assert_equal %w[bob@example.org carol@example.net dan@example.io eve@example.co].sort, addrs
  end

  def test_any_address_includes_from
    addrs = Array(Attr.resolve(multi_recipient, ["#any-address"])).map(&:address).sort
    assert_includes addrs, "alice@example.com"
    assert_includes addrs, "bob@example.org"
    assert_includes addrs, "eve@example.co"
  end

  def test_mailer_shorthand
    v = Attr.resolve(multi_recipient, ["#mailer"])
    assert_equal "TestMailer/1.0", v
  end

  def test_x_mailer_direct
    assert_equal "TestMailer/1.0", Attr.resolve(multi_recipient, ["x-mailer"])
  end

  def test_date_shorthand_returns_time_or_datetime
    t = Attr.resolve(single, ["#date"])
    assert t.is_a?(Time) || t.is_a?(DateTime), "expected Time/DateTime, got #{t.class}"
    assert_equal 2026, t.year
    assert_equal 3, t.month
    assert_equal 15, t.day
  end

  def test_date_sent_alias
    t = Attr.resolve(single, ["#date-sent"])
    assert t.is_a?(Time) || t.is_a?(DateTime), "expected Time/DateTime, got #{t.class}"
    assert_equal 2026, t.year
  end

  def test_date_received_returns_nil_when_no_received_header
    # Constructed Mail objects have no Received headers. The implementation
    # currently does NOT fall back to mail.date in that case — it returns nil.
    # Documenting the actual behavior, not aspirational behavior.
    assert_nil Attr.resolve(single, ["#date-received"])
  end

  # ---- list-id / in-reply-to ----

  def test_list_id_raw
    v = Attr.resolve(listy, ["list-id"])
    assert_match(/medium\.com/, v.to_s)
  end

  def test_list_id_identifier
    assert_equal "medium.com", Attr.resolve(listy, ["list-id", "identifier"])
  end

  def test_list_id_description
    assert_equal "Medium Daily", Attr.resolve(listy, ["list-id", "description"])
  end

  def test_in_reply_to_returns_value
    v = Attr.resolve(multi_recipient, ["in-reply-to"])
    assert_match(/parent@example\.com/, v.to_s)
  end

  # ---- AddressValue step decomposition ----

  def test_from_name_step
    assert_equal "Alice Example", Attr.resolve(single, %w[from name])
  end

  def test_from_address_step
    assert_equal "alice@example.com", Attr.resolve(single, %w[from address])
  end

  def test_from_domain_step
    assert_equal "example.com", Attr.resolve(single, %w[from domain])
  end

  def test_from_user_step
    assert_equal "alice", Attr.resolve(single, %w[from user])
  end

  def test_from_top_level_domain
    assert_equal "com", Attr.resolve(single, %w[from domain top-level])
  end

  def test_from_second_level_domain
    assert_equal "example", Attr.resolve(single, %w[from domain second-level])
  end

  def test_from_address_top_level
    # Direct step on AddressValue without going through .domain first
    assert_equal "com", Attr.resolve(single, %w[from address top-level])
  end

  def test_multi_level_domain
    mail = Mail.new do
      from    "user@mail.eng.example.co.uk"
      subject "x"
      date    Time.now.rfc2822
    end
    assert_equal "uk", Attr.resolve(mail, %w[from domain top-level])
    assert_equal "co", Attr.resolve(mail, %w[from domain second-level])
    assert_equal "example", Attr.resolve(mail, %w[from domain third-level])
    assert_equal "mail", Attr.resolve(mail, %w[from domain final-level])
  end

  # ---- subject step decomposition ----

  def test_subject_body_strips_re_and_brackets
    mail = single
    mail.subject = "Re: [Tag] Real Subject"
    assert_equal "Real Subject", Attr.resolve(mail, %w[subject body])
  end

  def test_subject_blob_extracts_bracket_content
    mail = single
    mail.subject = "Re: [Project-X] Update"
    assert_equal "Project-X", Attr.resolve(mail, %w[subject blob])
  end

  def test_subject_prefix_returns_re_chain
    mail = single
    mail.subject = "Re: Fwd: Hello"
    prefix = Attr.resolve(mail, %w[subject prefix])
    assert_match(/Re:/i, prefix)
    assert_match(/Fwd:/i, prefix)
  end

  def test_subject_body_handles_nested_re
    mail = single
    mail.subject = "Re: Re: Re: Final"
    assert_equal "Final", Attr.resolve(mail, %w[subject body])
  end

  # ---- Time step decomposition ----

  def test_date_year_step
    assert_equal "2026", Attr.resolve(single, ["#date", "year"])
  end

  def test_date_month_step
    assert_equal "3", Attr.resolve(single, ["#date", "month"])
  end

  def test_date_day_step
    assert_equal "15", Attr.resolve(single, ["#date", "day"])
  end

  def test_date_hour_step
    assert_equal "12", Attr.resolve(single, ["#date", "hour"])
  end

  # ---- thread-id heuristic ----

  def test_thread_id_uses_references_root
    assert_equal "root@example.com", Attr.resolve(multi_recipient, ["##thread-id"])
  end

  def test_thread_id_falls_back_to_in_reply_to
    mail = Mail.new do
      from "a@b.com"
      to   "c@d.com"
      subject "x"
      date Time.now.rfc2822
    end
    mail["In-Reply-To"] = "<parent-only@example.com>"
    assert_equal "parent-only@example.com", Attr.resolve(mail, ["##thread-id"])
  end

  def test_thread_id_falls_back_to_own_message_id
    mail = single
    mail.message_id = "own@example.com"
    assert_equal "own@example.com", Attr.resolve(mail, ["##thread-id"])
  end

  # ---- index-only mode (no Mail object) ----

  def test_resolve_with_nil_mail_returns_nil_for_header_paths
    fake = Object.new
    def fake.mail; nil; end
    def fake.eml_id; nil; end
    assert_nil Attr.resolve(fake, ["from"])
    assert_nil Attr.resolve(fake, ["subject"])
  end

  def test_flags_nil_without_eml_id
    # head_values returns [] for #flags with no eml_id; resolve then flattens
    # away the empty array and returns nil. Either way, the answer is "no flags."
    assert_nil Attr.resolve(single, ["#flags"])
  end

  # ---- multi-value path semantics ----

  def test_recipient_address_multi
    addrs = Array(Attr.resolve(multi_recipient, %w[#recipient address])).sort
    assert_equal %w[bob@example.org carol@example.net dan@example.io eve@example.co].sort, addrs
  end

  def test_any_address_domain_multi
    domains = Array(Attr.resolve(multi_recipient, %w[#any-address domain])).uniq.sort
    assert_includes domains, "example.com"
    assert_includes domains, "example.org"
  end

  # ---- domain_level edge cases via internal API ----

  def test_domain_level_helper
    assert_equal "uk", Attr.domain_level("a.b.example.co.uk", "top-level")
    assert_equal "co", Attr.domain_level("a.b.example.co.uk", "second-level")
    assert_nil Attr.domain_level("", "top-level")
  end

  # ---- subject helpers directly ----

  def test_strip_subject_prefixes_handles_locales
    assert_equal "Hi", Attr.strip_subject_prefixes("Re: Hi")
    assert_equal "Hi", Attr.strip_subject_prefixes("Fwd: Hi")
    assert_equal "Hi", Attr.strip_subject_prefixes("AW: Hi")
    assert_equal "Real", Attr.strip_subject_prefixes("Re: [Tag] Real")
  end

  def test_subject_blob_returns_nil_when_no_bracket
    assert_nil Attr.subject_blob("Plain subject")
  end
end
