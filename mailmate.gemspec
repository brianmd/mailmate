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
  spec.homepage    = "https://github.com/brianmd/mailmate"
  spec.required_ruby_version = ">= 3.0"

  # Without these, the rubygems.org page carries no link back to the source —
  # which is how 1.0.0 through 1.7.0 shipped. `source_code_uri` renders the
  # "Source Code" link. No `homepage_uri`: it would duplicate spec.homepage
  # above, and `gem build` warns that only the first of the two is shown.
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "#{spec.homepage}#readme"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "LICENSE.txt",
    "README.md",
    "config.yml.example",
    # Shipped because --help and the MCP instructions point at
    # docs/Composing and threading.md by path; without this the pointer
    # dangles for anyone who installed the gem rather than cloned the repo.
    # (roadmap/ is deliberately excluded — internal planning, not user docs.)
    "docs/*.md",
  ]
  spec.bindir      = "exe"
  spec.executables = Dir["exe/*"].map { |p| File.basename(p) }
  spec.require_paths = ["lib"]

  spec.add_dependency "mail", "~> 2.8"
  # csv was a default gem through Ruby 3.3; 3.4+ requires it explicitly.
  spec.add_dependency "csv", "~> 3.0"
  # `mmmessage --markdown` (and the MCP `message` tool's markdown:true) and
  # ReplyPrefill's quoted original (mm-send --reply-to/--forward, markdownr's
  # compose) use reverse_markdown (which pulls nokogiri) to render HTML
  # bodies as readable markdown (Mailmate::HtmlMarkdown). Kept OPTIONAL so the base install stays free of native
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
