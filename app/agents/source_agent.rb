# frozen_string_literal: true

# Shared base for the per-source triage agents. They're identical except for HOW
# each reaches its inbox (which tools it attaches). Each runs a :local sandbox
# (rooted at SANDBOX_DIR when instantiated with cwd:) and may write its digest
# fragment there; mail access stays read-only.
class SourceAgent < Nexo::Agent
  model               ENV.fetch("LLM_MODEL", "glm-5.2:cloud")
  provider            :ollama
  assume_model_exists true
  sandbox             :local
  permissions         Nexo::Permissions.new(mode: :read_only, allow: SANDBOX_WRITE)
  skills              :email_triage

  instructions <<~TXT
    You triage ONE email inbox with the attached email_triage skill: read recent
    messages, classify them, and compose the digest. When the prompt names a file,
    save the digest there with the write tool and confirm in one line. Work with
    the mail-reading tools you were given plus the write tool.
  TXT

  # Plain (non-MCP) RubyLLM tool classes to attach for this source; MCP-backed
  # sources leave this empty and use the `mcp` macro instead.
  def self.source_tools = []

  # Preflight availability check. Returns nil when the source can run, or a short
  # human-readable reason string when it cannot (missing binary, missing creds).
  # The workflow skips unavailable sources and reports the reason instead of
  # letting the whole run trip over them. Base is always available; subclasses
  # override with their own binary/credential checks.
  def self.availability = nil

  # Pure-Ruby PATH lookup (no shell): true when +cmd+ is an executable on PATH.
  def self.command?(cmd)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, cmd)
      File.file?(path) && File.executable?(path)
    end
  end

  # Attach the source's tools on top of Nexo's normal wiring (super builds the chat
  # with instructions, sandbox tools, MCP, etc.; with_tools is additive).
  def chat(base: nil)
    chat = super
    tools = self.class.source_tools.map(&:new)
    chat.with_tools(*tools) unless tools.empty?
    chat
  end
end
