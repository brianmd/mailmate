# frozen_string_literal: true

require_relative "lib/mailmate/version"

Gem::Specification.new do |spec|
  spec.name        = "mailmate"
  spec.version     = Mailmate::VERSION
  spec.authors     = ["Brian Murphy-Dye"]
  spec.email       = ["brian@murphydye.com"]

  spec.summary     = "Ruby toolkit for MailMate on macOS — search, read, modify, send, and smart-mailbox evaluation"
  spec.description = <<~DESC
    mailmate is a Ruby library and CLI for working with MailMate's on-disk
    storage and AppleScript surface. It includes a smart-mailbox filter
    engine (lexer/parser/evaluator over MailMate's filter language), readers
    for the binary header indexes, and CLI tools for searching, reading,
    modifying, and sending mail via MailMate.

    Requires macOS with MailMate installed. Some library pieces (parser,
    evaluator, fixture-driven tests) work on any platform; the integration
    pieces (AppleScript driver, filesystem readers) raise Mailmate::PlatformError
    on non-macOS hosts.
  DESC
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "LICENSE.txt",
    "README.md",
    "config.yml.example",
  ]
  spec.bindir      = "exe"
  spec.executables = Dir["exe/*"].map { |p| File.basename(p) }
  spec.require_paths = ["lib"]

  spec.add_dependency "mail", "~> 2.8"
  # csv was a default gem through Ruby 3.3; 3.4+ requires it explicitly.
  spec.add_dependency "csv", "~> 3.0"
  # `mmmessage --markdown` (and the MCP `message` tool's markdown:true) use
  # reverse_markdown (which pulls nokogiri) to render HTML-only bodies as
  # readable markdown. Kept OPTIONAL so the base install stays free of native
  # extensions — users who never invoke --markdown don't need a compiler if
  # nokogiri lacks a precompiled binary for their Ruby/platform. If --markdown
  # is used without the gem present, mmmessage warns with a clear
  # `gem install reverse_markdown` hint and falls back to raw HTML (it does
  # NOT exit — the in-process MCP server must survive a missing optional dep).

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  # Development-only — see runtime-deps comment above. Kept here so the
  # test suite (which exercises `mmmessage --markdown`) has nokogiri +
  # reverse_markdown available without forcing them on every end-user.
  spec.add_development_dependency "reverse_markdown", "~> 3.0"
end
