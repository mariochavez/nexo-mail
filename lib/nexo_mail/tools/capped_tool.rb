# frozen_string_literal: true

module NexoMail
  module Tools
    # Bounds the size of an MCP tool's reply. Wraps a tool, delegates everything, and
    # truncates whatever comes back past a character budget.
    #
    # Why this exists: Gmail and HEY are ours, so their tools bound themselves. Apple
    # Mail is reached through a third-party MCP server (apple-mail-mcp) whose
    # `get_email` returns the FULL body with no cap and no batching — one call can be
    # larger than an entire HEY box listing. We cannot batch someone else's server, but
    # we can refuse to let one reply eat the context.
    #
    # The model is TOLD it was truncated rather than handed a silently short body, so
    # it can decide whether the missing tail mattered.
    #
    # Composes on top of Nexo::MCP::GatedTool, which is itself a duck-typed delegating
    # wrapper: #name/#description/#params_schema fall through to the real tool, so the
    # chat cannot tell any of the three apart. Authorization still happens in the
    # GatedTool underneath — this wrapper only ever sees an already-permitted call.
    class CappedTool
      MARKER = "\n\n[truncated — body exceeded the configured limit; ask for a specific detail if you need more]"

      def initialize(tool:, max_chars:)
        @tool = tool
        @max_chars = max_chars
      end

      def call(args = {})
        cap(@tool.call(args))
      end

      # Mirror GatedTool: #execute must route through #call so no caller can reach the
      # unwrapped body by taking the other entry point.
      def execute(*args, **kwargs)
        call(kwargs.empty? ? (args.first || {}) : kwargs)
      end

      def name = @tool.name

      def respond_to_missing?(method_name, include_private = false)
        return true if method_name == :execute

        @tool.respond_to?(method_name, include_private) || super
      end

      # Everything except the two entry points above (description, params_schema,
      # to_h, ...) goes straight to the wrapped tool so it serializes identically.
      def method_missing(method_name, *args, **kwargs, &block)
        if @tool.respond_to?(method_name)
          @tool.public_send(method_name, *args, **kwargs, &block)
        else
          super
        end
      end

      private

      # Truncates the payload's text without changing its type — a String stays a
      # String, anything else is measured by its serialized length and only rebuilt as
      # a String when it actually overflows.
      def cap(result)
        return result if result.nil?

        text = result.is_a?(String) ? result : result.to_s
        return result if text.length <= @max_chars

        text[0, @max_chars] + MARKER
      end
    end
  end
end
