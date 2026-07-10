# frozen_string_literal: true

# Read-only Gmail access over IMAP using a Gmail App Password — no gcloud, no GCP
# project, no OAuth client. Ruby stdlib only. This module holds the shared
# connection helper; the tools live in gmail_imap/list.rb and gmail_imap/read.rb.
#
# The mailbox is opened with EXAMINE (read-only), so the tools cannot mark, move,
# or modify any message — read-only is guaranteed by the IMAP protocol state.
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
end
