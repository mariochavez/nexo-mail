# frozen_string_literal: true

# Gmail — reached read-only over IMAP with an App Password (no gcloud/gws needed).
# To use the `gws` OAuth CLI instead, swap in [GwsGmailUnread, GwsGmailRead].
class GmailSource < SourceAgent
  def self.source_tools = [GmailImap::List, GmailImap::Read]

  def self.availability
    return nil unless ENV["GMAIL_ADDRESS"].to_s.empty? || ENV["GMAIL_APP_PASSWORD"].to_s.empty?

    "set GMAIL_ADDRESS and GMAIL_APP_PASSWORD (Gmail App Password)"
  end
end
