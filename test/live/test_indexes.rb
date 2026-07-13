# frozen_string_literal: true

require_relative "test_helper_live"

# Decode every binary index in Database.noindex/Headers/. Each .offsets file
# must be a valid 12-byte-record stream, and no read should fall out of
# bounds against its paired .cache. Catches index-format drift in MailMate.
class TestLiveIndexes < Minitest::Test
  include Mailmate::TestHelpers
  include Mailmate::LiveTestHelpers

  def setup
    require_live_mailmate
  end

  def test_all_indexes_decode_without_raising
    db_headers = Mailmate.config.db_headers
    skip "no #{db_headers}" unless File.directory?(db_headers)

    failures = []
    Dir.glob(File.join(db_headers, "*.offsets")).each do |offsets_path|
      name = File.basename(offsets_path, ".offsets")
      cache_path = "#{db_headers}/#{name}.cache"
      next unless File.exist?(cache_path) # paired files only

      offsets_size = File.size(offsets_path)
      unless (offsets_size % 12).zero?
        failures << "#{name}.offsets size #{offsets_size} not a multiple of 12"
        next
      end

      begin
        reader = Mailmate::IndexReader.for(name)
        # Iterate every record and assert value lookup doesn't raise.
        reader.each_record do |_id, _value|
          # the iteration itself exercises slice access
        end
      rescue StandardError => e
        failures << "#{name}: #{e.class}: #{e.message}"
      end
    end
    assert_empty failures, "index decode failures:\n#{failures.join("\n")}"
  end
end
