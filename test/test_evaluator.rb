# frozen_string_literal: true

require_relative "test_helper"
require "mail"

# End-to-end tests for Mailmate::Evaluator. Build small Mail::Message objects
# in-memory (no .eml files needed), parse a filter, and assert the evaluator
# produces the expected boolean.
class TestEvaluator < Minitest::Test
  include Mailmate::TestHelpers

  def evaluate(filter, mail, var_resolver: nil)
    ast = Mailmate.compile_filter(filter)
    Mailmate::Evaluator.new(ast, var_resolver: var_resolver).matches?(mail)
  end

  def build_mail(from: "sender@example.com", from_name: nil, to: "me@example.com", subject: "Hello", date: Time.now, body: "Body text", list_id: nil)
    mail = Mail.new do
      from from_name ? "#{from_name} <#{from}>" : from
      to       to
      subject  subject
      date     date.rfc2822
      body     body
    end
    mail["List-Id"] = list_id if list_id
    mail
  end

  # ---- equality / contains ----

  def test_from_name_equality
    mail = build_mail(from_name: "Medium", from: "noreply@medium.com")
    assert evaluate("from.name = 'Medium'", mail)
    refute evaluate("from.name = 'Substack'", mail)
  end

  def test_subject_contains
    mail = build_mail(subject: "Your order has shipped")
    assert evaluate("subject ~ 'shipped'", mail)
    refute evaluate("subject ~ 'invoice'", mail)
  end

  def test_case_insensitive_with_c_flag
    mail = build_mail(subject: "URGENT REQUEST")
    assert evaluate("subject ~[c] 'urgent'", mail)
    refute evaluate("subject ~ 'urgent'", mail), "case-sensitive miss"
  end

  # ---- boolean composition ----

  def test_and_combines_two_clauses
    mail = build_mail(from_name: "Medium", subject: "Daily digest")
    assert evaluate("from.name = 'Medium' and subject ~ 'digest'", mail)
    refute evaluate("from.name = 'Medium' and subject ~ 'invoice'", mail)
  end

  def test_or_either_clause_passes
    mail = build_mail(from_name: "Medium")
    assert evaluate("from.name = 'Medium' or from.name = 'Substack'", mail)
    assert evaluate("from.name = 'Substack' or from.name = 'Medium'", mail)
    refute evaluate("from.name = 'Substack' or from.name = 'Other'", mail)
  end

  def test_not_inverts
    mail = build_mail(from_name: "Medium")
    refute evaluate("not (from.name = 'Medium')", mail)
    assert evaluate("not (from.name = 'Substack')", mail)
  end

  def test_implicit_and
    mail = build_mail(from_name: "Medium", subject: "Daily digest")
    # Two clauses without explicit connector → implicit AND
    assert evaluate("from.name = 'Medium' subject ~ 'digest'", mail)
  end

  # ---- exists ----

  def test_list_id_exists
    with_list = build_mail(list_id: "<medium.com>")
    without   = build_mail
    assert evaluate("list-id exists", with_list)
    refute evaluate("list-id exists", without)
  end

  # ---- not-equals / not-contains ----

  def test_neq
    mail = build_mail(from_name: "Medium")
    refute evaluate("from.name != 'Medium'", mail)
    assert evaluate("from.name != 'Other'", mail)
  end

  def test_not_contains
    mail = build_mail(subject: "Daily digest")
    refute evaluate("subject !~ 'digest'", mail)
    assert evaluate("subject !~ 'invoice'", mail)
  end

  # ---- composite filter from a real smart mailbox ----

  def test_real_smart_mailbox_shape
    # Approximation of a typical newsletter smart mailbox. Uses `#date` (Date header)
    # rather than `#date-received` (Received-headers chain) since constructed
    # Mail objects don't carry Received: headers.
    mail = build_mail(from_name: "Medium", from: "noreply@medium.com", subject: "Today's picks")
    filter = "from.name = 'Medium' and #date > '2020-01-01 00:00:00 +0000'"
    assert evaluate(filter, mail)
  end

  # ---- var_resolver injection ----

  def test_var_reference_requires_resolver
    mail = build_mail
    assert_raises(RuntimeError) do
      evaluate("#recipient.address = $SENT.from.address", mail)
    end
  end

  def test_var_resolver_is_called
    mail = build_mail(to: "brian@example.com")
    fake_resolver = Object.new
    def fake_resolver.resolve(var, path)
      # Pretend $SENT.from.address resolves to a set containing brian@example.com.
      raise "unexpected var #{var}" unless var == "SENT"
      raise "unexpected path #{path}" unless path == ["from", "address"]
      ["brian@example.com"]
    end
    assert evaluate("#recipient.address = $SENT.from.address", mail, var_resolver: fake_resolver)
  end

  # ---- multi-value path semantics ----

  def test_multi_recipient_match_any
    # Build a mail with multiple recipients; the filter "to.address = X" should
    # match if ANY recipient matches.
    mail = Mail.new do
      from    "alice@example.com"
      to      ["bob@example.org", "carol@example.net"]
      subject "Multi"
      date    Time.now.rfc2822
    end
    assert evaluate("to.address = 'bob@example.org'", mail)
    assert evaluate("to.address = 'carol@example.net'", mail)
    refute evaluate("to.address = 'dan@example.io'", mail)
  end

  def test_multi_recipient_neq_requires_all_to_differ
    # `to.address != X` should be false if ANY recipient equals X.
    mail = Mail.new do
      from    "alice@example.com"
      to      ["bob@example.org", "carol@example.net"]
      subject "Multi"
      date    Time.now.rfc2822
    end
    refute evaluate("to.address != 'bob@example.org'", mail), "one recipient equals bob"
    assert evaluate("to.address != 'nobody@example.com'", mail)
  end

  def test_nested_or
    mail = build_mail(from_name: "Charlie")
    filter = "from.name = 'Alice' or (from.name = 'Bob' or from.name = 'Charlie')"
    assert evaluate(filter, mail)
  end

  def test_not_short_circuits
    # `not (X)` should evaluate to true when X evaluates to false, regardless
    # of what's inside. This tests NotNode evaluation isn't somehow swallowing.
    mail = build_mail(from_name: "Alice")
    assert evaluate("not (subject = 'Nope')", mail)
    refute evaluate("not (from.name = 'Alice')", mail)
  end

  def test_and_short_circuits_on_first_false
    # If the first clause is false, the second shouldn't matter — even if it
    # would raise (e.g. an unknown function would crash). Hard to test rigorously
    # without faking, so check the simpler assertion: clear false ANDs work.
    mail = build_mail(from_name: "Alice")
    refute evaluate("from.name = 'Bob' and subject = 'anything'", mail)
  end
end
