# frozen_string_literal: true

require "rake/testtask"

# Hermetic tests — run anywhere, no MailMate required.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"].exclude("test/live/**/*")
  t.warning = false
end

# Live tests — opt-in, requires a real MailMate install on macOS.
namespace :test do
  Rake::TestTask.new(:live) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/live/test_*.rb"]
    t.warning = false
  end
end

task default: :test

# One-command release. This guards the MECHANICS of a release — clean tree,
# green tests, version actually bumped, tag + build + sync + publish all
# happening, in order — not the judgment of whether the features are done;
# that stays with the human running it (as does the RubyGems OTP prompt,
# which is why Claude hands this command to the user rather than running
# it). Preconditions fail fast before anything irreversible.
desc "Release the current version: verify clean tree + green tests + unreleased version, then tag, build, sync, gem push"
task :release do
  require_relative "lib/mailmate/version"
  version = Mailmate::VERSION

  abort "release: working tree is dirty — commit first" unless `git status --porcelain`.strip.empty?
  abort "release: tag v#{version} already exists — bump lib/mailmate/version.rb first" unless `git tag -l v#{version}`.strip.empty?
  Rake::Task[:test].invoke

  sh "gem", "build", "mailmate.gemspec"
  sh "git", "tag", "v#{version}"
  sh "git-sync"
  # git-sync doesn't carry tags; a tag push is additive (no clobber risk),
  # which is what the pre-push hook's escape hatch is for.
  sh({ "GIT_SYNC" => "1" }, "git", "push", "origin", "refs/tags/v#{version}")
  sh "gem", "push", "mailmate-#{version}.gem" # prompts for the RubyGems OTP
  puts "\nreleased mailmate #{version} — remember: gem install ./mailmate-#{version}.gem to update PATH"
end
