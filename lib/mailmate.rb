# frozen_string_literal: true

# @api public
#
# mailmate — Ruby toolkit for MailMate on macOS.
#
# Public surface:
#   Mailmate.config                            → singleton Config (data only; use the accessor)
#   Mailmate.compile_filter(string)            → filter AST root
#   Mailmate::Identity.mine?(addr)             → is this address one of mine?
#   Mailmate::IndexReader.for(name)            → decoded Database.noindex/Headers/<name>
#   Mailmate::PartLookup.body_parts_of(envelope_id) → child body-part-ids of an envelope
#   Mailmate::EmlLookup.path_for(eml_id)       → eml-id → absolute path
#   Mailmate::HeaderReader.header(path, name)  → read one header from an .eml
#   Mailmate::HeaderValue.sanitize(v)          → CR/LF-safe --header value (ALL header paths use this)
#   Mailmate::ReplyPrefill.build(id, mode:)    → reply/reply-all/forward fields from a parent
#   Mailmate::MidUrl.for(message_id)           → build a mid:%3C...%3E URL
#   Mailmate::DuplicateScanner.duplicates      → Hash{Message-ID => Array<eml_id>}
#   Mailmate::AppleScriptDriver.new(...)       → drive MailMate via AppleScript
#   Mailmate::Evaluator.new(ast).matches?(msg) → smart-mailbox filter evaluation
#   Mailmate::MailboxGraph.load                → graph of all configured mailboxes
#   Mailmate::SourceResolver.new(graph)        → resolves mailbox → on-disk dirs
#   Mailmate::Message                          → thin wrapper over Mail + eml_id
#   Mailmate::PlatformError                    → raised when macOS bits are needed elsewhere
#
# Internal (subject to change without notice; do not depend on these):
#   Mailmate::Config (use Mailmate.config), Lexer, Parser, AST, Operators,
#   Attributes, FilterClassifier, VarResolver, Mailmate::CLI::*.

module Mailmate
end

require_relative "mailmate/version"
require_relative "mailmate/platform_error"
require_relative "mailmate/config"
require_relative "mailmate/identity"
require_relative "mailmate/header_reader"
require_relative "mailmate/mid_url"
require_relative "mailmate/eml_lookup"
require_relative "mailmate/header_value"
require_relative "mailmate/reply_prefill"
require_relative "mailmate/duplicate_scanner"
require_relative "mailmate/applescript_driver"
require_relative "mailmate/ast"
require_relative "mailmate/lexer"
require_relative "mailmate/parser"
require_relative "mailmate/message"
require_relative "mailmate/index_reader"
require_relative "mailmate/part_lookup"
require_relative "mailmate/attributes"
require_relative "mailmate/operators"
require_relative "mailmate/evaluator"
require_relative "mailmate/mailbox_graph"
require_relative "mailmate/source_resolver"
require_relative "mailmate/var_resolver"
require_relative "mailmate/filter_classifier"
require_relative "mailmate/search_syntax"

module Mailmate
  # First-run bootstrap. If ~/.config/mailmate/config.yml is missing,
  # interactively run `mmdiscover` (TTY callers) or warn once and continue
  # with built-in defaults (non-TTY: MCP server, scripts, cron jobs).
  #
  # Idempotent: only checks once per process. Triggered automatically by
  # `Mailmate.config`, so every CLI and the MCP server pick it up without
  # extra wiring.
  def self.ensure_configured!(stdin: $stdin, stderr: $stderr)
    return if @configured_checked
    @configured_checked = true
    return if File.exist?(Config::DEFAULT_CONFIG_PATH)

    if stdin.tty?
      stderr.puts "mailmate: no config found at #{Config::DEFAULT_CONFIG_PATH} — running first-run setup (mmdiscover)."
      require_relative "mailmate/cli/discover"
      Mailmate::CLI::Discover.run([])
      Mailmate::Config.reload!
    else
      stderr.puts "mailmate: no config at #{Config::DEFAULT_CONFIG_PATH}; using built-in defaults. Run `mmdiscover` once in a terminal for identity-aware output."
    end
  end

  def self.compile_filter(str)
    Parser.parse(Lexer.lex(str))
  end

  # Convert a Time to the configured display zone.
  # If `display_timezone` is set in config, use it as the offset (e.g.
  # "-07:00"). Otherwise fall back to the system local zone (which honors
  # macOS's DST rules, so Mountain users get MDT in summer and MST in winter).
  def self.localize(time)
    return nil unless time
    t = time.respond_to?(:to_time) ? time.to_time : time
    zone = config.display_timezone
    if zone && !zone.empty?
      t.getlocal(zone)
    else
      t.getlocal
    end
  rescue StandardError
    time
  end
end
