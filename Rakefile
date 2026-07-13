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
