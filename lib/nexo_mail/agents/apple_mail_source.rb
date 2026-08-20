# frozen_string_literal: true

module NexoMail
  module Agents
    # Apple Mail — reached through the apple-mail-mcp server, gated read-only. Same
    # sandbox grant as the base, plus the read-only MCP allow-list.
    #
    # Apple Mail is the one source whose reads we cannot batch: apple-mail-mcp is a
    # third-party server, and its `get_email` takes exactly one message_id and returns
    # the FULL body with no cap. The two levers we do have are both applied here —
    # the reply size (see #apply_mcp) and the instructions (the email_triage skill
    # tells the agent to lean on `search`, which returns content_snippet for many
    # messages at once, instead of calling `get_email` per message).
    class AppleMailSource < SourceAgent
      permissions Nexo::Permissions.new(mode: :read_only, allow: NexoMail::SANDBOX_WRITE, mcp_allow: NexoMail::MAIL_READ_TOOLS)
      mcp :mail, transport: :stdio, command: Config.apple_mail_mcp_command

      def self.prompt_key = "apple_mail"

      def self.availability
        cmd = Config.apple_mail_mcp_command
        command?(cmd) ? nil : "#{cmd} not found on PATH"
      end

      private

      # Wraps every MCP tool in a size cap on top of Nexo's permission gate, so a
      # single untruncated get_email cannot eat the context the way it can today.
      # Gmail's and HEY's tools bound themselves; this is the equivalent for a server
      # we do not own.
      #
      # NOTE: #apply_mcp is a Nexo::Agent internal, not a published extension point —
      # re-check it on any nexo_ai upgrade (verified against ~> 0.9). If it ever stops being
      # called, the failure is loud: Apple Mail loses its tools entirely rather than
      # silently losing the cap.
      def apply_mcp(chat)
        super
        cap = Config.apple_body_chars
        chat.tools.transform_values! do |tool|
          mcp_tool?(tool) ? Tools::CappedTool.new(tool: tool, max_chars: cap) : tool
        end
        chat
      end

      # Only the gated MCP tools get capped — the sandbox read/write/glob tools are
      # ours and already bounded.
      def mcp_tool?(tool) = tool.is_a?(Nexo::MCP::GatedTool)
    end
  end
end
