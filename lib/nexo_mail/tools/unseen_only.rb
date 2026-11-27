# frozen_string_literal: true

module NexoMail
  module Tools
    # Drops the messages a ledger has already seen from an MCP listing tool's reply.
    #
    # Gmail and HEY are ours, so their listing tools consult the ledger themselves.
    # Apple Mail is reached through a third-party MCP server with no cursor of any
    # kind — `get_emails` and `search` return the same mail on every run — so the
    # filter goes around the tool instead, the same way CappedTool bounds its size.
    #
    # Conservative by construction: it only acts on a reply it fully understands (a
    # JSON array of objects, each with an `id`). Anything else — an error string, a
    # shape the server changes to — passes through untouched, which costs a re-read
    # and never hides mail.
    class UnseenOnly < McpWrapper
      def initialize(tool:, ledger:)
        super(tool: tool)
        @ledger = ledger
      end

      private

      def transform(result)
        text = text_of(result)
        return result unless text

        rows = JSON.parse(text)
        rows = rows["result"] if rows.is_a?(Hash) && rows["result"].is_a?(Array)
        return result unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row.key?("id") }

        fresh = @ledger.take(rows) { |row| row["id"] }
        shown, routed = SenderMemory.route(fresh) do |row|
          {id: row["id"], sender: row["sender"], sender_email: row["sender"], subject: row["subject"],
           received_at: row["date_received"] || row["date"]}
        end
        @ledger.route(routed)
        JSON.generate(
          messages: shown,
          count: shown.size,
          already_triaged: rows.size - fresh.size,
          routed_ephemeral: routed.size,
          note: "Only mail not triaged by an earlier run is listed. `lane`, when present, is where this sender's mail has gone before."
        )
      rescue JSON::ParserError
        result
      end
    end
  end
end
