# frozen_string_literal: true

require "net/imap"
require "date"
require "ruby_llm"

# Read-only Gmail access over IMAP using a Gmail App Password — no gcloud, no GCP
# project, no OAuth client. Ruby stdlib only. The mailbox is opened with EXAMINE
# (read-only), so these tools cannot mark, move, or modify any message even if the
# model asked — read-only is guaranteed by the IMAP protocol state, not just policy.
#
# Setup: enable 2-Step Verification, create an App Password at
# https://myaccount.google.com/apppasswords, then export:
#   GMAIL_ADDRESS=you@gmail.com
#   GMAIL_APP_PASSWORD='xxxx xxxx xxxx xxxx'   (spaces are ignored)
module GmailImap
  HOST = "imap.gmail.com"

  module_function

  # Connects, logs in, opens INBOX read-only, yields the imap handle, and always
  # tears the connection down. Returns whatever the block returns, or an { error: }
  # hash (recoverable for the model) on a missing credential / login / network fault.
  def with_inbox
    address  = ENV["GMAIL_ADDRESS"].to_s
    password = ENV["GMAIL_APP_PASSWORD"].to_s.gsub(/\s+/, "")
    if address.empty? || password.empty?
      return {error: "set GMAIL_ADDRESS and GMAIL_APP_PASSWORD (a Gmail App Password) to use Gmail"}
    end

    imap = Net::IMAP.new(HOST, ssl: true)
    begin
      imap.login(address, password)
      imap.examine("INBOX") # READ-ONLY select — cannot set \Seen, move, or delete
      yield imap
    ensure
      imap.logout rescue nil
      imap.disconnect rescue nil
    end
  rescue Net::IMAP::NoResponseError => e
    {error: "Gmail IMAP login failed: #{e.message} — check the App Password and that IMAP is enabled"}
  rescue => e
    {error: "Gmail IMAP error: #{e.class}: #{e.message}"}
  end

  # Format an IMAP ENVELOPE address struct as "Name <mailbox@host>".
  def format_address(addr)
    return nil unless addr

    email = [addr.mailbox, addr.host].compact.join("@")
    addr.name ? "#{addr.name} <#{email}>" : email
  end

  # --- Tools ----------------------------------------------------------------
  # List recent INBOX messages (metadata only — enough to classify).
  class List < RubyLLM::Tool
    description "List recent Gmail INBOX messages (uid, from, subject, date) as JSON. Read-only."
    param :only_unread, type: :boolean, required: false, desc: "Only unread messages (default true)"
    param :limit, type: :integer, required: false, desc: "Max messages, newest first (default 20)"
    param :since_days, type: :integer, required: false, desc: "Only messages newer than N days (optional)"

    def execute(only_unread: true, limit: 20, since_days: nil)
      GmailImap.with_inbox do |imap|
        criteria = []
        criteria << "UNSEEN" if only_unread
        if since_days
          # IMAP SINCE matches on the server's date; anchor to UTC so the "last N
          # days" boundary is deterministic regardless of the local zone.
          since = (Time.now.utc.to_date - since_days.to_i).strftime("%d-%b-%Y")
          criteria += ["SINCE", since]
        end
        criteria = ["ALL"] if criteria.empty?

        uids = imap.uid_search(criteria).last(limit.to_i)
        next {messages: []} if uids.empty?

        rows = imap.uid_fetch(uids, %w[ENVELOPE INTERNALDATE FLAGS]).map do |d|
          env = d.attr["ENVELOPE"]
          {
            uid: d.attr["UID"],
            from: GmailImap.format_address(env&.from&.first),
            subject: env&.subject,
            date: (env&.date || d.attr["INTERNALDATE"]).to_s,
            unread: !Array(d.attr["FLAGS"]).include?(:Seen)
          }
        end
        {messages: rows.reverse} # newest first
      end
    end
  end

  # Read one message's body by UID (best-effort plain text).
  class Read < RubyLLM::Tool
    description "Read one Gmail message body by its UID (best-effort plain text) as JSON. Read-only."
    param :uid, type: :integer, required: true, desc: "The UID from the list tool"

    def execute(uid:)
      GmailImap.with_inbox do |imap|
        # BODY.PEEK[TEXT] fetches the body WITHOUT setting the \Seen flag.
        data = imap.uid_fetch(uid.to_i, ["BODY.PEEK[TEXT]", "ENVELOPE"])
        next {error: "message uid #{uid} not found"} if Array(data).empty?

        d = data.first
        {
          uid: uid,
          subject: d.attr["ENVELOPE"]&.subject,
          body: d.attr["BODY[TEXT]"].to_s.strip[0, 4000]
        }
      end
    end
  end
end
