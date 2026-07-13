# frozen_string_literal: true

# Resolves a mailbox UUID (or smart-mailbox `set`) to a list of `Messages/`
# directories on disk. Walks the `set` chain to handle nested smart mailboxes:
# the chain ends at a special UUID (ALL_MESSAGES, INBOX, SENT, etc.) which
# maps to actual on-disk paths.
#
# Also returns an accumulated list of filters from any smart mailboxes
# encountered along the way — these AND with the leaf mailbox's filter.

module Mailmate
  # @api public
  class SourceResolver
    # Standard-mailbox name patterns. Each special UUID maps to one or more
    # `*.mailbox` directories per account. Gmail nests system folders under
    # `[Gmail]/...`; iCloud is flat with different names.
    SPECIAL_DIRS = {
      "INBOX"   => ["INBOX.mailbox"],
      "DRAFTS"  => ["[Gmail].mailbox/Drafts.mailbox", "Drafts.mailbox"],
      "SENT"    => ["[Gmail].mailbox/Sent Mail.mailbox", "Sent Messages.mailbox"],
      "ARCHIVE" => ["[Gmail].mailbox/Archive.mailbox", "Archive.mailbox"],
      "JUNK"    => ["[Gmail].mailbox/Spam.mailbox", "Junk.mailbox"],
      "TRASH"   => ["[Gmail].mailbox/Trash.mailbox", "Deleted Messages.mailbox"],
    }.freeze

    # ALL_MESSAGES: union of INBOX/SENT/DRAFTS/ARCHIVE plus any custom labels.
    # Excludes Trash/Junk (per MailMate help: "All Messages" is everything except
    # deleted/junk).
    ALL_MESSAGES_EXCLUDES = %r{/(?:Trash|Junk|Spam|Deleted Messages)\.mailbox/Messages/?\z}.freeze

    def initialize(graph)
      @graph = graph
    end

    # Resolve a mailbox spec to {dirs:, filters:}.
    # `spec` may be a UUID, a name, or a special UUID literal.
    # Returns:
    #   :dirs    => Array<String> of absolute paths to `Messages/` directories
    #   :filters => Array<String> of filter expressions to AND together
    def resolve(spec)
      filters = []
      uuid = spec
      visited = []
      loop do
        raise ArgumentError, "Cycle in mailbox resolution: #{visited.inspect}" if visited.include?(uuid)
        visited << uuid

        m = @graph.by_uuid[uuid] || @graph.by_uuid[@graph.by_name[uuid]]

        # Collect this node's filter (if it has one). The special UUIDs
        # FLAGGED / SENT / etc. can themselves be smart mailboxes (e.g.
        # Brian's "Flagged" with filter `#flags.flag = '\Flagged'`); the
        # filter has to be picked up before we resolve the special to dirs.
        filters << m[:filter] if m && m[:filter]

        next_uuid = m && m[:set]

        # If `set` points elsewhere, walk to it (handles nested smart mailboxes).
        if next_uuid && next_uuid != uuid
          uuid = next_uuid
          next
        end

        # Terminal — resolve to on-disk dirs.
        if MailboxGraph::SPECIAL_UUIDS.include?(uuid)
          return { dirs: special_dirs(uuid), filters: filters }
        end

        raise ArgumentError, "Mailbox #{spec.inspect} can't be resolved to disk paths " \
                             "(uuid=#{uuid}, name=#{m && m[:name].inspect})"
      end
    end

    def special_dirs(uuid)
      case uuid
      when "ALL_MESSAGES"
        all_message_dirs
      when "INBOX", "DRAFTS", "SENT", "ARCHIVE", "JUNK", "TRASH"
        per_account_dirs(SPECIAL_DIRS[uuid])
      else
        # Unknown special — return empty list and let the caller fail loudly.
        []
      end
    end

    def all_message_dirs
      Dir.glob("#{Mailmate.config.imap_root}/*/**/Messages")
         .select { |p| File.directory?(p) }
         .reject { |p| p =~ ALL_MESSAGES_EXCLUDES }
    end

    def per_account_dirs(suffixes)
      result = []
      Dir.glob("#{Mailmate.config.imap_root}/*").each do |account|
        next unless File.directory?(account)
        suffixes.each do |suffix|
          d = "#{account}/#{suffix}/Messages"
          result << d if File.directory?(d)
        end
      end
      result
    end
  end
end
