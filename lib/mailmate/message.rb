# frozen_string_literal: true

# Message — thin wrapper that pairs a parsed Mail::Message with its `.eml`
# body-part ID and on-disk path. Stage B+ attribute paths (`#flags.flag`,
# `#date-last-viewed`, …) need the body-part ID to look up MailMate's binary
# Database.noindex/Headers indexes; carrying it alongside the Mail object lets
# the resolver fetch indexed values without re-deriving the ID.
#
# Delegates the headers-and-body interface back to Mail so existing code that
# expects a `Mail::Message` keeps working unchanged.

module Mailmate
  # @api public
  class Message
    attr_reader :mail, :eml_id, :path

    def initialize(mail, eml_id, path)
      @mail = mail
      @eml_id = eml_id.to_i
      @path = path
    end

    # Delegate the headers/body methods Attributes uses.
    %i[from to cc bcc reply_to sender subject date message_id received body
       text_part html_part attachments].each do |m|
      define_method(m) { mail.public_send(m) }
    end

    def [](key); mail[key]; end
  end
end
