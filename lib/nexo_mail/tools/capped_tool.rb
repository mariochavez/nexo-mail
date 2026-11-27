# frozen_string_literal: true

module NexoMail
  module Tools
    # Bounds the size of an MCP tool's reply: whatever comes back past a character
    # budget is cut, and the model is TOLD so rather than handed a silently short
    # body, so it can decide whether the missing tail mattered.
    #
    # Why this exists: Gmail and HEY are ours, so their tools bound themselves. Apple
    # Mail is reached through a third-party MCP server (apple-mail-mcp) whose
    # `get_email` returns the FULL body with no cap and no batching — one call can be
    # larger than an entire HEY box listing. We cannot batch someone else's server, but
    # we can refuse to let one reply eat the context.
    class CappedTool < McpWrapper
      MARKER = "\n\n[truncated — body exceeded the configured limit; ask for a specific detail if you need more]"

      def initialize(tool:, max_chars:)
        super(tool: tool)
        @max_chars = max_chars
      end

      private

      # A reply within the budget is returned as it came, whatever its type. One past
      # it becomes its text, cut. A reply with no text (an image, say) is left alone.
      def transform(result)
        text = text_of(result)
        return result if text.nil? || text.length <= @max_chars

        text[0, @max_chars] + MARKER
      end
    end
  end
end
