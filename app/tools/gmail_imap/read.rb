# frozen_string_literal: true

# Reads one message's body by UID (best-effort plain text).
class GmailImap::Read < RubyLLM::Tool
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
