# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/cli/send"
require "tmpdir"

class TestSend < Minitest::Test
  include Mailmate::TestHelpers

  # Point EMATE_PATH at `path` for the duration of the block.
  def with_emate(path)
    orig = Mailmate::CLI::Send::EMATE_PATH
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, path)
    yield
  ensure
    Mailmate::CLI::Send.send(:remove_const, :EMATE_PATH)
    Mailmate::CLI::Send.const_set(:EMATE_PATH, orig)
  end

  # A fake emate that records its argv and stdin to `capture` and prints
  # canned output on both streams, so tests can observe exactly what the
  # child received and where its output went.
  def write_fake_emate(dir, capture)
    fake = File.join(dir, "fake-emate")
    File.write(fake, <<~SH)
      #!/bin/sh
      { echo "ARGV: $*"; echo "--- STDIN ---"; cat; } > "#{capture}"
      echo "emate-stdout-marker"
      echo "emate-stderr-marker" >&2
    SH
    File.chmod(0o755, fake)
    fake
  end

  def test_run_returns_exit_code_when_emate_missing
    actual = nil
    with_emate("/nonexistent/emate") do
      capture_subprocess_io { actual = Mailmate::CLI::Send.run(["--to", "x@y.z"]) }
    end
    assert_equal 1, actual
  end

  def test_run_returns_integer_when_emate_present
    actual = nil
    with_emate("/usr/bin/true") do
      # `true` ignores its args and exits 0. The point is that run() returns
      # an Integer instead of replacing the process.
      with_stdin("") { capture_subprocess_io { actual = Mailmate::CLI::Send.run([]) } }
    end
    assert_kind_of Integer, actual
    assert_equal 0, actual
  end

  # ---- fd hygiene: the MCP body-swallowing bug (2026-08-06) ----

  def test_body_reaches_emate_on_a_private_pipe_not_inherited_fd0
    Dir.mktmpdir do |dir|
      capture = File.join(dir, "capture.txt")
      fake = write_fake_emate(dir, capture)
      actual = nil
      with_emate(fake) do
        # $stdin is a StringIO — exactly the MCP server's with_stdin swap.
        # Under the old system() spawn the child could not see it and read
        # the process's real fd 0 instead.
        with_stdin("THE REAL COMPOSED BODY") do
          capture_subprocess_io { actual = Mailmate::CLI::Send.run(["-t", "x@y.z", "-s", "subj"]) }
        end
      end
      assert_equal 0, actual
      captured = File.read(capture)
      assert_includes captured, "ARGV: mailto --markup markdown -t x@y.z -s subj"
      assert_includes captured, "THE REAL COMPOSED BODY"
    end
  end

  def test_emate_output_is_reemitted_through_ruby_globals
    Dir.mktmpdir do |dir|
      fake = write_fake_emate(dir, File.join(dir, "capture.txt"))
      out_io = StringIO.new
      err_io = StringIO.new
      old_out, old_err = $stdout, $stderr
      begin
        $stdout, $stderr = out_io, err_io
        with_emate(fake) do
          with_stdin("body") { Mailmate::CLI::Send.run(["-t", "x@y.z"]) }
        end
      ensure
        $stdout, $stderr = old_out, old_err
      end
      # Captured via the globals (what the MCP's with_captured_io swaps), not
      # written to the process's real fd 1/2 — which in the MCP server is the
      # JSON-RPC transport.
      assert_includes out_io.string, "emate-stdout-marker"
      assert_includes err_io.string, "emate-stderr-marker"
    end
  end

  def test_help_does_not_consume_stdin
    Dir.mktmpdir do |dir|
      fake = write_fake_emate(dir, File.join(dir, "capture.txt"))
      stdin_io = StringIO.new("should stay unread")
      old = $stdin
      begin
        $stdin = stdin_io
        with_emate(fake) { capture_subprocess_io { Mailmate::CLI::Send.run(["--help"]) } }
      ensure
        $stdin = old
      end
      # An interactive `mm-send --help` must not hang waiting for Ctrl-D.
      assert_equal 0, stdin_io.pos
    end
  end
end
