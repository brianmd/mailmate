# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/verify"
require "tmpdir"
require "fileutils"

# Tests for Mailmate::CLI::Verify — ticket parsing and batch evaluation of
# #flags expectations. The polling timing is exercised only at the predicate
# level (a synthetic index that already satisfies / never satisfies).
class TestCliVerify < Minitest::Test
  include Mailmate::TestHelpers

  V = Mailmate::CLI::Verify

  # ---- parse_tickets: array, NDJSON, single object ----

  def test_parse_tickets_json_array
    raw = '[{"eml_id":1,"expectations":[]},{"eml_id":2,"expectations":[]}]'
    assert_equal [1, 2], V.parse_tickets(raw).map { |t| t["eml_id"] }
  end

  def test_parse_tickets_ndjson
    # What `mm-modify --emit-check` prints when appended line-by-line.
    raw = %({"eml_id":1,"expectations":[]}\n{"eml_id":2,"expectations":[]}\n)
    assert_equal [1, 2], V.parse_tickets(raw).map { |t| t["eml_id"] }
  end

  def test_parse_tickets_single_object
    assert_equal [7], V.parse_tickets('{"eml_id":7,"expectations":[]}').map { |t| t["eml_id"] }
  end

  # ---- check_all against a synthetic #flags index ----

  def test_check_all_passes_and_fails_per_ticket
    with_flags_index(1 => "\\Seen urgent", 2 => "\\Seen") do
      tickets = [
        { "eml_id" => 1, "message_id" => "<a>", "expectations" => [["tag_present", "urgent"]] },
        { "eml_id" => 2, "message_id" => "<b>", "expectations" => [["tag_present", "urgent"]] },
      ]
      results = V.check_all(tickets)
      assert_equal true,  results[0]["ok"]
      assert_equal false, results[1]["ok"]
      assert_equal ["tag \"urgent\""], results[1]["unmet"]
    end
  end

  def test_check_all_empty_expectations_auto_pass
    with_flags_index(1 => "") do
      results = V.check_all([{ "eml_id" => 1, "expectations" => [] }])
      assert results[0]["ok"]
    end
  end

  # ---- verify summary + exit semantics ----

  def test_verify_summary_all_pass
    with_flags_index(1 => "done") do
      summary = V.verify([{ "eml_id" => 1, "expectations" => [["tag_present", "done"]] }],
                         timeout: 0.2, poll: 0.05)
      assert_equal 1, summary["passed"]
      assert_equal 0, summary["failed"]
    end
  end

  def test_verify_summary_reports_failure_after_timeout
    with_flags_index(1 => "") do
      summary = V.verify([{ "eml_id" => 1, "expectations" => [["flagged", true]] }],
                         timeout: 0.15, poll: 0.05)
      assert_equal 0, summary["passed"]
      assert_equal 1, summary["failed"]
      assert_equal ["flagged"], summary["results"][0]["unmet"]
    end
  end

  def test_run_returns_3_when_any_ticket_fails
    with_flags_index(1 => "") do
      argv = ["--check-timeout", "0.1", "--poll", "0.05", "--compact",
              '[{"eml_id":1,"expectations":[["flagged",true]]}]']
      out, code = capture_stdout_with_code { V.run(argv) }
      assert_equal 3, code
      assert_match(/"failed":1/, out)
    end
  end

  def test_run_returns_0_when_all_pass
    with_flags_index(1 => "\\Flagged") do
      argv = ["--compact", '[{"eml_id":1,"expectations":[["flagged",true]]}]']
      out, code = capture_stdout_with_code { V.run(argv) }
      assert_equal 0, code
      assert_match(/"failed":0/, out)
    end
  end

  private

  # Build a synthetic #flags index from {eml_id => "space sep flags"} and
  # point config at it.
  def with_flags_index(map)
    Dir.mktmpdir do |dir|
      headers = File.join(dir, "Database.noindex", "Headers")
      FileUtils.mkdir_p(headers)
      cache = +""
      offsets = +""
      map.each do |eml_id, flags|
        start = cache.bytesize
        cache << flags
        offsets << [eml_id, start, cache.bytesize].pack("V3")
      end
      File.binwrite(File.join(headers, "#flags.cache"), cache)
      File.binwrite(File.join(headers, "#flags.offsets"), offsets)
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        Mailmate::IndexReader.reset!
        yield
      end
    end
  end

  def capture_stdout_with_code
    orig = $stdout
    $stdout = StringIO.new
    code = yield
    [$stdout.string, code]
  ensure
    $stdout = orig
  end
end
