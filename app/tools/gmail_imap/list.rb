# frozen_string_literal: true

# Lists recent INBOX messages (metadata only — enough to classify).
class GmailImap::List < RubyLLM::Tool
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
