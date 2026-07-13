# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "mailmate"

module Mailmate
  module TestHelpers
    FIXTURES_DIR = File.expand_path("fixtures", __dir__)

    def fixture_path(*parts)
      File.join(FIXTURES_DIR, *parts)
    end

    def fixture_read(*parts)
      File.read(fixture_path(*parts))
    end

    # Run a block with a freshly-loaded Config, optionally with a given YAML
    # path and ENV. Useful for testing config loading without leaking state.
    # Saves and restores the original instance via Mailmate::Config.reload!.
    def with_config(yaml_path: "/nonexistent", env: {})
      orig = Mailmate::Config.instance_variable_get(:@instance)
      Mailmate::Config.reload!(yaml_path: yaml_path, env: env)
      yield
    ensure
      Mailmate::Config.instance_variable_set(:@instance, orig)
      Mailmate::IndexReader.reset!
    end
  end
end
