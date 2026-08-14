# frozen_string_literal: true

require_relative "header_value"

module Mailmate
  # @api public
  #
  # Derive the fields of a reply / reply-all / forward from a parent message:
  # recipients, subject, threading headers, and the quoted original.
  #
  # This is the ONE place the References chain is constructed. It is exposed as
  # a library call (not just a CLI behavior) because consumers need the pieces
  # WITHOUT sending — markdownr's compose popup fills a form from them, and
  # `mm-send --reply-to` turns them into emate flags. Two implementations of
  # "parent's References + parent's Message-ID" is how one of them silently
  # stops threading; there is only this one.
  #
  # Rules it encodes (canonical prose: docs/Composing and threading.md):
  #   * In-Reply-To = the parent's Message-ID.
  #   * References  = the parent's References (if any) + the parent's
  #     Message-ID appended; the bare Message-ID when the parent is a root.
  #   * A forward does NOT thread. It is a new conversation sent to someone who
  #     was not party to the original, so injecting the original's chain would
  #     graft a stranger into a thread they can't see. Forward derives the
  #     subject and the quoted original only.
  module ReplyPrefill
    extend self

    MODES = %w[reply reply-all forward].freeze

    class NotFound < StandardError; end

    Prefill = Struct.new(
      :mode, :from, :to, :cc, :subject, :in_reply_to, :references, :quoted_body,
      :parent_message_id, :parent_eml_id,
      keyword_init: true
    ) do
      def to_h
        super.transform_keys(&:to_s)
      end
    end

    # `input` is an eml-id or an RFC Message-ID (bracketed or not) — anything
    # EmlLookup.resolve_id accepts. `identities` defaults to the configured
    # list; pass an explicit array to override (markdownr passes what
    # mmdiscover reported, which may be broader than config.yml).
    def build(input, mode: "reply", identities: nil)
      mode = mode.to_s
      raise ArgumentError, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(mode)

      mail, eml_id = load_parent(input)
      idents = normalize_identities(identities)

      message_id = HeaderValue.bracket_message_id(mail.message_id)
      threading  = mode == "forward" ? { in_reply_to: nil, references: nil } : {
        in_reply_to: presence(message_id),
        references: build_references(mail, message_id)
      }

      Prefill.new(
        mode: mode,
        from: pick_from_identity(mail, idents),
        to: derive_to(mail, mode),
        cc: derive_cc(mail, mode, idents),
        subject: derive_subject(mail, mode),
        quoted_body: derive_quoted_body(mail, mode),
        parent_message_id: presence(message_id),
        parent_eml_id: eml_id,
        **threading
      )
    end

    private

    def load_parent(input)
      eml_id = Mailmate::EmlLookup.resolve_id(input)
      raise NotFound, "couldn't resolve #{input.inspect} as an eml-id or Message-ID" if eml_id.nil? || eml_id.zero?

      path = Mailmate::EmlLookup.path_for(eml_id)
      raise NotFound, "no .eml on disk for eml-id #{eml_id}" unless path

      require "mail"
      [Mail.read(path), eml_id]
    end

    # References = parent's own chain + parent's Message-ID. A parent that is
    # itself a thread root has no References, so the chain is just its id.
    def build_references(mail, message_id)
      old = HeaderValue.sanitize(mail["references"]&.value)
      presence(old.empty? ? message_id : "#{old} #{message_id}".strip)
    end

    # Reply goes to Reply-To when the sender set one, else From. A forward has
    # no derivable recipient — that's the caller's whole reason for forwarding.
    def derive_to(mail, mode)
      return [] if mode == "forward"

      reply_to = addresses(mail.reply_to).first
      [reply_to || addresses(mail.from).first].compact
    end

    # Reply-all carries the other recipients, minus every address of ours (so
    # switching identity can't leave us Cc'ing ourselves) and minus whoever
    # already landed in To.
    def derive_cc(mail, mode, idents)
      return [] unless mode == "reply-all"

      to_lc = derive_to(mail, mode).map(&:downcase)
      (addresses(mail.to) + addresses(mail.cc))
        .reject { |a| idents.include?(a.downcase) || to_lc.include?(a.downcase) }
        .uniq
    end

    def derive_subject(mail, mode)
      subject = mail.subject.to_s.strip
      mode == "forward" ? ensure_prefix(subject, "Fwd", /\Afwd?\s*:/i) : ensure_prefix(subject, "Re", /\Are\s*(?:\[\d+\])?\s*:/i)
    end

    # Conservative: never double-prefix, and leave an existing prefix in
    # whatever case/shape the sender used (`RE:`, `Re[2]:`) alone.
    def ensure_prefix(subject, word, already)
      return "#{word}: " if subject.empty?
      return subject if subject.match?(already)

      "#{word}: #{subject}"
    end

    # Whichever of OUR addresses the parent was addressed to — so a reply goes
    # out from the identity that received it, not from whatever MailMate
    # defaults to. nil when we can't tell; the caller decides the fallback.
    def pick_from_identity(mail, idents)
      return nil if idents.empty?

      candidates = addresses(mail.to) + addresses(mail.cc) + addresses(mail.bcc)
      candidates.find { |a| idents.include?(a.downcase) }
    end

    # Reply: email-classic "On <date>, <sender> wrote:" + a `> `-prefixed body.
    # Forward: the conventional un-prefixed forwarded-message block with its
    # own header summary, since the recipient has never seen the original.
    def derive_quoted_body(mail, mode)
      body = plain_body(mail)
      from = presence(mail["from"]&.value.to_s.strip) || "(unknown sender)"
      date = mail["date"]&.value.to_s.strip

      if mode == "forward"
        header = ["---------- Forwarded message ----------",
                  "From: #{from}",
                  ("Date: #{date}" unless date.empty?),
                  "Subject: #{mail.subject.to_s.strip}",
                  ("To: #{mail['to'].value}" if mail["to"])].compact.join("\n")
        return "#{header}\n\n#{body}"
      end

      attribution = date.empty? ? "#{from} wrote:" : "On #{date}, #{from} wrote:"
      return "#{attribution}\n> [no plain-text alternative — paste the original manually]\n" if body.strip.empty?

      quoted = body.sub(/\n+\z/, "").split("\n", -1).map { |l| "> #{l}".rstrip }.join("\n")
      "#{attribution}\n#{quoted}\n"
    end

    # The text/plain alternative, or "" when the message is HTML-only. We do
    # NOT synthesize text from the HTML part here: a lossy auto-conversion
    # quoted back to the original sender is worse than an honest placeholder.
    def plain_body(mail)
      part = mail.multipart? ? mail.text_part : mail
      return "" if part.nil?
      return "" if part.respond_to?(:mime_type) && part.mime_type && part.mime_type != "text/plain"

      part.body.decoded.to_s
    rescue StandardError
      ""
    end

    # Mail's address fields raise on malformed input often enough that a reply
    # to a slightly-broken message shouldn't blow up the whole derivation.
    def addresses(field)
      Array(field).map { |a| a.to_s.strip }.reject(&:empty?)
    rescue StandardError
      []
    end

    def normalize_identities(identities)
      list = identities.nil? ? Mailmate::Identity.list : Array(identities)
      list.map { |a| a.to_s.downcase.strip }.reject(&:empty?)
    end

    def presence(str)
      s = str.to_s.strip
      s.empty? ? nil : s
    end
  end
end
