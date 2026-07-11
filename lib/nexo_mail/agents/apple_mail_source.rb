# frozen_string_literal: true

module NexoMail
  module Agents
    # Apple Mail — reached through the apple-mail-mcp server, gated read-only. Same
    # sandbox grant as the base, plus the read-only MCP allow-list.
    class AppleMailSource < SourceAgent
      permissions Nexo::Permissions.new(mode: :read_only, allow: NexoMail::SANDBOX_WRITE, mcp_allow: NexoMail::MAIL_READ_TOOLS)
      mcp :mail, transport: :stdio, command: Config.apple_mail_mcp_command

      def self.prompt_key = "apple_mail"

      def self.availability
        cmd = Config.apple_mail_mcp_command
        command?(cmd) ? nil : "#{cmd} not found on PATH"
      end
    end
  end
end
