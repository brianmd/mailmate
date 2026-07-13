# frozen_string_literal: true

module Mailmate
  # Shared #flags expectation predicate, used by both the inline check in
  # `mm-modify` and the batch `mm-verify`. An "expectation" is a [kind, arg]
  # pair describing the post-action state a single eml-id's flag list should
  # satisfy; `kind` may be a Symbol (internal) or String (round-tripped
  # through a JSON check-ticket) — both resolve the same.
  #
  # Kinds:
  #   [:seen, true|false]         \Seen present / absent
  #   [:flagged, true|false]      \Flagged present / absent
  #   [:tag_present, "name"]      keyword present
  #   [:tag_absent, "name"]       keyword absent
  #   [:no_user_tags, nil]        no non-system keywords (only \… / $… remain)
  module FlagCheck
    module_function

    def met?(flags, kind, arg)
      case kind.to_sym
      when :seen         then flags.include?("\\Seen") == arg
      when :flagged      then flags.include?("\\Flagged") == arg
      when :tag_present  then flags.include?(arg)
      when :tag_absent   then !flags.include?(arg)
      when :no_user_tags then flags.none? { |f| !system_flag?(f) }
      else raise ArgumentError, "unknown flag-check kind: #{kind.inspect}"
      end
    end

    # All expectations satisfied by `flags`? `expectations` is an array of
    # [kind, arg] pairs.
    def all_met?(flags, expectations)
      expectations.all? { |kind, arg| met?(flags, kind, arg) }
    end

    def system_flag?(flag)
      flag.start_with?("\\", "$")
    end

    # Human label for an expectation, for verification messages.
    def label(kind, arg)
      case kind.to_sym
      when :seen         then arg ? "read" : "unread"
      when :flagged      then arg ? "flagged" : "not flagged"
      when :tag_present  then "tag #{arg.inspect}"
      when :tag_absent   then "no tag #{arg.inspect}"
      when :no_user_tags then "no user tags"
      end
    end
  end
end
