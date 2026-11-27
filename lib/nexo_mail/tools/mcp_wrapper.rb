# frozen_string_literal: true

module NexoMail
  module Tools
    # A wrapper around one MCP tool that rewrites what the tool returns. Subclasses
    # define #transform; everything else — the name, the description, the parameter
    # schema — falls through to the wrapped tool, so the chat cannot tell them apart.
    #
    # Composes on top of Nexo::MCP::GatedTool (handed over by Nexo::Agent#wrap_mcp_tool
    # AFTER the permission gate wrapped the tool), so a wrapper only ever sees an
    # already-permitted call.
    class McpWrapper
      def initialize(tool:)
        @tool = tool
      end

      # ruby_llm calls every tool with keywords (`tool.call(**arguments)`).
      def call(**arguments)
        transform(@tool.call(**arguments))
      end

      # Mirror GatedTool: #execute routes through #call, so no caller can reach the
      # unwrapped reply by taking the other entry point.
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

      # The reply's text, or nil for a shape this does not understand. An MCP tool
      # answers with a RubyLLM::MCP::Result, whose text is #text — its #to_s is an
      # object address, not the reply.
      def text_of(result)
        return result if result.is_a?(String)
        return result.text if result.respond_to?(:text) && result.text.is_a?(String)

        nil
      end
    end
  end
end
