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
    class UnseenOnly
      def initialize(tool:, ledger:)
        @tool = tool
        @ledger = ledger
      end

      def call(**arguments)
        filter(@tool.call(**arguments))
      end

      # Mirror GatedTool/CappedTool: #execute routes through #call.
      def execute(*args, **kwargs)
        call(**(args.first || {}).to_h, **kwargs)
      end

      def name = @tool.name

      def respond_to_missing?(method_name, include_private = false)
        return true if method_name == :execute

        @tool.respond_to?(method_name, include_private) || super
      end

      def method_missing(method_name, *args, **kwargs, &block)
        if @tool.respond_to?(method_name)
          @tool.public_send(method_name, *args, **kwargs, &block)
        else
          super
        end
      end

      private

      def filter(result)
        text = text_of(result)
        return result unless text

        rows = JSON.parse(text)
        rows = rows["result"] if rows.is_a?(Hash) && rows["result"].is_a?(Array)
        return result unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row.key?("id") }

        fresh = @ledger.take(rows) { |row| row["id"] }
        JSON.generate(
          messages: fresh,
          count: fresh.size,
          already_triaged: rows.size - fresh.size,
          note: "Only mail not triaged by an earlier run is listed."
        )
      rescue JSON::ParserError
        result
      end

      # MCP replies arrive as a String or as a content object that prints as one.
      def text_of(result)
        return result if result.is_a?(String)
        return result.text if result.respond_to?(:text) && result.text.is_a?(String)

        nil
      end
    end
  end
end
