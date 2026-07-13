# frozen_string_literal: true

# Attribute resolver: maps a path like ["from", "name"] or ["#any-address"]
# to one or more values on a parsed Mail::Message. Implements the subset of
# /Applications/MailMate.app/Contents/Resources/specifiers.plist that Brian's
# smart-mailbox filters actually reference.
#
# Returns:
#   - String  for single-valued paths
#   - Array<String> for multi-valued paths (e.g. recipient lists, all-addresses)
#   - Time    for date paths
#   - nil     when the value is missing/empty
#
# Stage A subset (no #flags / #date-last-viewed access; those need IndexReader).

require "time"
require_relative "index_reader"

# @api private
module Mailmate
  module Attributes
    SHORTHANDS = {
      "#recipient"   => %w[to cc bcc],
      "#any-address" => %w[from to cc bcc],
      "#mailer"      => %w[x-mailer user-agent x-newsreader],
      "#date"        => :date,
      "#date-received" => :date_received,
      "#date-sent"   => :date,
    }.freeze

    # Resolve a path to value(s). Returns nil/[] when nothing.
    # `mail_or_message` may be a Mail::Message OR a Mailmate::Message (which
    # carries the `eml_id` needed for index-based attributes like `#flags`).
    def self.resolve(mail_or_message, path)
      mail   = mail_or_message.respond_to?(:mail) ? mail_or_message.mail : mail_or_message
      eml_id = mail_or_message.respond_to?(:eml_id) ? mail_or_message.eml_id : nil

      head, *rest = path
      values = head_values(mail, head, eml_id)
      values = Array(values).flatten.compact
      return nil if values.empty?

      rest.each do |seg|
        values = values.flat_map { |v| step(v, seg) }.compact
        return nil if values.empty?
      end

      values.size == 1 ? values.first : values
    end

    # ---- head resolution ----

    INDEX_DATE_HEADS = %w[#date #date-sent #date-received #date-last-viewed].freeze

    def self.head_values(mail, head, eml_id = nil)
      # Index-backed paths: never need the Mail object.
      if INDEX_DATE_HEADS.include?(head) && eml_id
        s = (IndexReader.for(head).value_for(eml_id) rescue nil)
        return nil if s.nil? || s.empty?
        begin
          return Time.parse(s)
        rescue ArgumentError
          return nil
        end
      end

      case head
      when "##thread-id"
        # Heuristic thread-id: root Message-ID of the References chain (or
        # In-Reply-To, or the message's own Message-ID). Requires the headers
        # — return nil cleanly if we're in index-only mode without a Mail.
        return nil if mail.nil?
        thread_id_for(mail)
      when "#flags"
        # Returns the raw flag tokens as strings (e.g. ["\\Seen", "$Forwarded"]).
        # Empty array if the message has no flags / isn't indexed.
        # Resolved via the binary `Database.noindex/Headers/#flags` index.
        return [] if eml_id.nil?
        IndexReader.for("#flags").flags_for(eml_id)
      when "##tags"
        return [] if eml_id.nil?
        # ##tags is a related index (multiValue) for user-facing tag names.
        # Best-effort: fall back to #flags if ##tags isn't present.
        begin
          IndexReader.for("##tags").flags_for(eml_id)
        rescue ArgumentError
          IndexReader.for("#flags").flags_for(eml_id)
        end
      else
        # All other heads need the Mail object. In index-only mode, mail is
        # nil — return nil so comparisons fail cleanly rather than crashing.
        return nil if mail.nil?
        head_values_from_mail(mail, head)
      end
    end

    def self.head_values_from_mail(mail, head)
      case head
      when "from"
        addrs(mail, :from)
      when "to"
        addrs(mail, :to)
      when "cc"
        addrs(mail, :cc)
      when "bcc"
        addrs(mail, :bcc)
      when "reply-to"
        addrs(mail, :reply_to)
      when "subject"
        mail.subject.to_s
      when "list-id"
        v = header_value(mail, "list-id")
        v && [v]
      when "in-reply-to"
        v = header_value(mail, "in-reply-to")
        v && [v]
      when "message-id"
        mail.message_id
      when "x-mailer", "user-agent", "x-newsreader"
        v = header_value(mail, head)
        v && [v]
      when "#recipient", "#any-address"
        SHORTHANDS[head].flat_map { |h| addrs(mail, h.to_sym) || [] }
      when "#mailer"
        SHORTHANDS[head].map { |h| header_value(mail, h) }.compact
      when "#date", "#date-sent"
        mail.date
      when "#date-received"
        # Best available proxy without IMAP: prefer the latest Received: timestamp,
        # falling back to the Date header. Receiving servers stamp Received headers
        # in reverse-chrono order; the topmost is the most recent.
        recv = mail.received
        recv = [recv].flatten.compact.first
        recv&.date_time && Time.parse(recv.date_time.to_s) rescue mail.date
      else
        # Unknown header — try as a raw header lookup.
        v = header_value(mail, head)
        v && [v]
      end
    end

    # Address fields can carry either an email or a display name. We return
    # *one Address-shaped string* per recipient, plus separately accessible
    # display names — `step` decomposes further on `.name` / `.address`.
    def self.addrs(mail, sym)
      field = mail[sym]
      return nil unless field
      list = Array(field.respond_to?(:addrs) ? field.addrs : nil)
      return [field.value.to_s] if list.empty?
      # Each Mail::Address has #display_name, #address, #name
      list.map { |a| AddressValue.new(a) }
    end

    # AddressValue wraps Mail::Address so `.step` knows what to extract.
    AddressValue = Struct.new(:addr) do
      def to_s
        if addr.display_name && !addr.display_name.empty?
          "#{addr.display_name} <#{addr.address}>"
        else
          addr.address.to_s
        end
      end

      def name
        addr.display_name
      end

      def address
        addr.address
      end
    end

    def self.header_value(mail, name)
      h = mail[name]
      return nil unless h
      h.value.to_s
    end

    # ---- decomposition step ----

    def self.step(value, seg)
      case value
      when AddressValue
        case seg
        when "name"    then value.name
        when "address" then value.address
        when "domain"
          a = value.address.to_s
          a.include?("@") ? a.split("@", 2).last : nil
        when "user"
          a = value.address.to_s
          a.include?("@") ? a.split("@", 2).first : a
        when "top-level", "second-level", "third-level", "final-level"
          a = value.address.to_s
          dom = a.include?("@") ? a.split("@", 2).last : nil
          dom && domain_level(dom, seg)
        else nil
        end
      when String
        case seg
        when "flag", "tag"
          # `#flags.flag` / `##tags.tag` — each value of the multi-value head
          # is already an individual flag/tag string. Passthrough.
          value
        when "body" # e.g. subject.body — strip Re:/Fwd: prefixes and [bracketed] blobs
          strip_subject_prefixes(value)
        when "blob"
          subject_blob(value)
        when "prefix"
          subject_prefix(value)
        when "identifier" # list-id <foo@bar>
          value =~ /<([^>]+)>/ ? Regexp.last_match(1) : value.strip
        when "description" # list-id "Description" <foo@bar>
          value =~ /^\s*"([^"]+)"|^([^<]+?)\s*</ ? (Regexp.last_match(1) || Regexp.last_match(2)).strip : nil
        when "user"
          value.include?("@") ? value.split("@", 2).first : value
        when "domain"
          value.include?("@") ? value.split("@", 2).last : nil
        when "top-level", "second-level", "third-level", "final-level"
          dom = value.include?("@") ? value.split("@", 2).last : value
          domain_level(dom, seg)
        else nil
        end
      when Time, DateTime
        t = value.respond_to?(:to_time) ? value.to_time : value
        case seg
        when "year"   then t.year.to_s
        when "month"  then t.month.to_s
        when "day"    then t.day.to_s
        when "hour"   then t.hour.to_s
        else nil
        end
      end
    end

    def self.strip_subject_prefixes(s)
      v = s.to_s.dup
      # Remove leading "Re:", "Fwd:", "[Tag]" sequences
      loop do
        if v.sub!(/\A\s*(?i:re|fw|fwd|sv|aw|antw|wg|tr)(?:\[\d+\])?\s*[:：]\s*/, "")
          next
        end
        if v.sub!(/\A\s*\[[^\[\]]+\]\s*/, "")
          next
        end
        break
      end
      v
    end

    def self.subject_blob(s)
      m = s.to_s.match(/\A(?:\s*(?i:re|fw|fwd|sv|aw|antw|wg|tr)(?:\[\d+\])?\s*[:：]\s*)*\s*\[([^\[\]]+)\]/)
      m && m[1]
    end

    def self.subject_prefix(s)
      m = s.to_s.match(/\A((?:\s*(?i:re|fw|fwd|sv|aw|antw|wg|tr)(?:\[\d+\])?\s*[:：]\s*)+)/)
      m && m[1].strip
    end

    # Thread-id heuristic: use the FIRST Message-ID in the References header
    # as the thread root, falling back to In-Reply-To, falling back to the
    # message's own Message-ID. Matches what most threading algorithms do.
    def self.thread_id_for(mail)
      refs = header_value(mail, "references").to_s
      if (m = refs.match(/<([^>]+)>/))
        return m[1]
      end
      irt = header_value(mail, "in-reply-to").to_s
      if (m = irt.match(/<([^>]+)>/))
        return m[1]
      end
      mid = mail.message_id.to_s
      mid = mid.tr("<>", "") if mid && !mid.empty?
      mid.empty? ? nil : mid
    end

    def self.domain_level(domain, level)
      parts = domain.to_s.split(".")
      return nil if parts.empty?
      case level
      when "top-level"    then parts[-1]
      when "second-level" then parts[-2]
      when "third-level"  then parts[-3]
      when "final-level"  then parts[0]
      end
    end
  end
end
