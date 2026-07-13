# frozen_string_literal: true

require "json"

# Reads MailMate's mailbox configuration: the user's `Mailboxes.plist` plus
# the bundled `standardMailboxes.plist`/`defaultMailboxes.plist`. Builds an
# in-memory graph keyed by UUID with name → uuid lookup.

module Mailmate
  # @api public
  class MailboxGraph
    APP_RESOURCES = "/Applications/MailMate.app/Contents/Resources"

    SPECIAL_UUIDS = %w[ALL_MESSAGES INBOX SENT DRAFTS ARCHIVE JUNK TRASH FLAGGED MAILBOXES PERSONAL_INBOX].freeze

    # Mailbox = a Hash with keys: :uuid, :name, :parent, :set, :filter
    attr_reader :by_uuid, :by_name

    def self.load
      new.tap(&:load!)
    end

    def initialize
      @by_uuid = {}
      @by_name = {}
    end

    def load!
      load_plist!("#{APP_RESOURCES}/standardMailboxes.plist")
      load_plist!("#{APP_RESOURCES}/defaultMailboxes.plist")
      load_plist!(Mailmate.config.mailboxes_plist)
      build_name_index!
      self
    end

    def lookup(name_or_uuid)
      @by_uuid[name_or_uuid] || @by_name[name_or_uuid]
    end

    private

    def load_plist!(path)
      return unless File.exist?(path)
      data = JSON.parse(`plutil -convert json -o - #{shellesc(path)}`)
      boxes = (data["mailboxes"] || []) + (data["deltaMailboxes"] || [])
      boxes.each do |m|
        next unless m["uuid"]
        existing = @by_uuid[m["uuid"]] || {}
        @by_uuid[m["uuid"]] = existing.merge(
          uuid:   m["uuid"],
          name:   m["name"]    || existing[:name],
          parent: m["parentUUID"] || existing[:parent],
          set:    m["set"]     || existing[:set],
          filter: m["filter"]  || existing[:filter],
          symbol: m["symbol"]  || existing[:symbol],
        )
      end
    end

    def build_name_index!
      @by_uuid.each do |uuid, m|
        next unless m[:name]
        # Prefer user-defined entries (later loads) over defaults; later loads
        # already overwrite earlier ones in @by_uuid via merge, but the name
        # index can still get clobbered when two mailboxes share a name.
        # We keep the most-recently-loaded — and for tied cases, prefer the
        # one that has a filter (smart mailboxes are what users address by name).
        existing = @by_name[m[:name]]
        @by_name[m[:name]] = uuid if existing.nil? || @by_uuid[existing][:filter].nil? || m[:filter]
      end
    end

    def shellesc(s)
      "'#{s.gsub("'", "'\\\\''")}'"
    end
  end
end
