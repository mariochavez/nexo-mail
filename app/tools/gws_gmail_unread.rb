# frozen_string_literal: true

# ALTERNATE Gmail path — the default is GmailImap over IMAP (lib/gmail_imap.rb).
# Lists Gmail messages via `gws gmail +triage`. Swap this (and GwsGmailRead) into
# GmailSource#source_tools to use the `gws` OAuth CLI instead of IMAP.
class GwsGmailUnread < RubyLLM::Tool
  description "List Gmail messages matching a query (default is:unread) as JSON: id, sender, subject, date. Read-only."
  param :query, type: :string, required: false, desc: "Gmail search query, e.g. 'is:unread' or 'newer_than:1d'"
  param :max, type: :integer, required: false, desc: "Max messages (default 20)"

  def execute(query: "is:unread", max: 20)
    CliReader.json(
      "gws", "gmail", "+triage", "--format", "json", "--query", query.to_s, "--max", max.to_i.to_s
    )
  end
end
