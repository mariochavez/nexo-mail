# frozen_string_literal: true

# Shared configuration for the triage agents: the LLM connection, the skills path,
# and the scratch workspace. Required by lib/multi_inbox.rb.
require "nexo"
require "ruby_llm/mcp"
require "logger"

# ruby_llm and ruby_llm-mcp are chatty (HTTP traces, "Index up to date", …), which
# clutters the pretty runner output. Silence both by default; RUBYLLM_WIRE=1 turns
# the raw HTTP/MCP trace back on for debugging.
QUIET_LOG = Logger.new(ENV["RUBYLLM_WIRE"] ? $stdout : File::NULL)
QUIET_LOG.level = ENV["RUBYLLM_WIRE"] ? Logger::DEBUG : Logger::FATAL

# ---------------------------------------------------------------------------
# LLM wiring: Ollama. RubyLLM's :ollama provider talks to Ollama's
# OpenAI-COMPATIBLE endpoint — note the /v1 suffix (NOT the native /api/chat).
# ---------------------------------------------------------------------------
RubyLLM.configure do |config|
  config.ollama_api_base = ENV.fetch("LLM_API_BASE", "http://localhost:11434/v1")
  # API key supplied via ENV (needed for Ollama Cloud / an authenticated proxy;
  # a plain local Ollama ignores it). Set only when present so local runs still work.
  config.ollama_api_key = ENV["LLM_API_KEY"] if ENV["LLM_API_KEY"]
  config.logger = QUIET_LOG
end

# ruby_llm-mcp keeps its OWN logger (the "Index up to date" line), so quiet it too.
if RubyLLM::MCP.respond_to?(:configure)
  RubyLLM::MCP.configure { |c| c.logger = QUIET_LOG }
elsif RubyLLM::MCP.respond_to?(:config)
  RubyLLM::MCP.config.logger = QUIET_LOG
end

# Resolve `skills :email_triage` from ./skills (this repo ships the SKILL.md at
# skills/email_triage/SKILL.md). In a Rails app this would default to app/skills.
Nexo.configure do |config|
  config.skills_path = File.expand_path("../skills", __dir__)
end

# Shared scratch workspace. Agents run a :local sandbox rooted here, so every file
# they write (per-source fragments + the final digest) is fenced to this one dir.
SANDBOX_DIR = File.expand_path("../sandbox", __dir__)
