# frozen_string_literal: true

# Apple Mail — reached through the apple-mail-mcp server, gated read-only. Same
# sandbox grant as the base, plus the read-only MCP allow-list.
class AppleMailSource < SourceAgent
  permissions Nexo::Permissions.new(mode: :read_only, allow: SANDBOX_WRITE, mcp_allow: MAIL_READ_TOOLS)
  mcp :mail, transport: :stdio, command: ENV.fetch("MAIL_MCP_COMMAND", "apple-mail-mcp")

  def self.availability
    cmd = ENV.fetch("MAIL_MCP_COMMAND", "apple-mail-mcp")
    command?(cmd) ? nil : "#{cmd} not found on PATH"
  end
end
