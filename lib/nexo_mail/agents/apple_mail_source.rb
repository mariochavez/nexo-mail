# frozen_string_literal: true

module NexoMail
  module Agents
    # Apple Mail — reached through the apple-mail-mcp server, gated read-only. Same
    # sandbox grant as the base, plus the read-only MCP allow-list.
    #
    # Apple Mail is the one source whose reads we cannot batch: apple-mail-mcp is a
    # third-party server, and its `get_email` takes exactly one message_id and returns
    # the FULL body with no cap. The two levers we do have are both applied here —
    # the reply size (see #wrap_mcp_tool) and the instructions (the email_triage skill
    # tells the agent to lean on `search`, which returns content_snippet for many
    # messages at once, instead of calling `get_email` per message).
    class AppleMailSource < SourceAgent
      permissions Nexo::Permissions.new(mode: :read_only, allow: NexoMail::SANDBOX_WRITE, mcp_allow: NexoMail::MAIL_READ_TOOLS)
      # ruby_llm's stdio transport leaves the server's stderr attached to ours, and
      # apple-mail-mcp is chatty there (its banner, plus a validation warning each
      # time ruby_llm probes it with a newer MCP revision before falling back). That
      # would land in the middle of the TUI, so it is dropped unless RUBYLLM_WIRE asks
      # to see the wire.
      if ENV["RUBYLLM_WIRE"]
        mcp :mail, transport: :stdio, command: Config.apple_mail_mcp_command
      else
        mcp :mail, transport: :stdio, command: "sh",
          args: ["-c", 'exec "$0" 2>/dev/null', Config.apple_mail_mcp_command]
      end

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
      # Nexo::Agent#wrap_mcp_tool is the published hook for this: it is handed each
      # MCP tool AFTER the permission gate has wrapped it, so the cap only ever sees
      # an already-permitted call.
      def wrap_mcp_tool(tool)
        Tools::CappedTool.new(tool: tool, max_chars: Config.apple_body_chars)
      end
    end
  end
end
