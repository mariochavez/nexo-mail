# frozen_string_literal: true

require "nexo"
require "ruby_llm/mcp"

# The Apple Mail READ tools this agent is allowed to invoke. Names must match the
# server EXACTLY (the MCP gate fails closed) — these are what this apple-mail-mcp
# build reports. Everything else it exposes (send/delete/flag/move) is denied.
MAIL_READ_TOOLS = %w[
  list_accounts
  list_mailboxes
  get_emails
  get_email
  search
  get_email_links
  get_email_attachment
].freeze

# ---------------------------------------------------------------------------
# LLM wiring: Ollama. RubyLLM's :ollama provider talks to Ollama's
# OpenAI-COMPATIBLE endpoint — note the /v1 suffix (NOT the native /api/chat).
# ---------------------------------------------------------------------------
RubyLLM.configure do |config|
  config.ollama_api_base = ENV.fetch("LLM_API_BASE", "http://localhost:11434/v1")
  # API key supplied via ENV (needed for Ollama Cloud / an authenticated proxy;
  # a plain local Ollama ignores it). Set only when present so local runs still work.
  config.ollama_api_key = ENV["LLM_API_KEY"] if ENV["LLM_API_KEY"]
end

# Resolve `skills :email_triage` from ./skills (this repo ships the SKILL.md at
# skills/email_triage/SKILL.md). In a Rails app this would default to app/skills.
Nexo.configure do |config|
  config.skills_path = File.expand_path("../skills", __dir__)
end

# MailTriage — a read-only agent that classifies your Apple Mail inbox and writes
# a markdown digest, driven by an Ollama model and reaching Mail through an MCP server.
class MailTriage < Nexo::Agent
  # The Ollama model tag. `:cloud` suffix ⇒ an Ollama Cloud model (needs
  # LLM_API_KEY + signin), not a local pull. It is not in ruby_llm's models.json,
  # so name the provider and skip the registry lookup (both required together).
  model               ENV.fetch("LLM_MODEL", "glm-5.2:cloud")
  provider            :ollama
  assume_model_exists true

  # Real-filesystem sandbox rooted at the agent's cwd, so it can WRITE the digest
  # file. (Was :virtual, which has no host filesystem.)
  sandbox :local

  # Custom gate: grant filesystem :write (to save the digest) on top of the
  # read-only defaults — but NOT via :auto, which would also un-gate every MCP
  # tool. The MCP axis stays fail-closed: only MAIL_READ_TOOLS are invokable, so
  # send/delete/flag/move remain denied. :shell is absent, so no shell either.
  permissions Nexo::Permissions.new(
    mode:      :read_only,
    allow:     %i[read glob write],
    mcp_allow: MAIL_READ_TOOLS
  )

  # Apple Mail is reached through the apple-mail-mcp server over stdio — never a
  # Mail SDK. Adjust `command`/`args` to however you launch your server; this
  # assumes the `apple-mail-mcp` executable is on PATH.
  #
  #   VERIFY the tool names against YOUR server — implementations differ. Any name
  #   not in MAIL_READ_TOOLS (send, delete, flag, move, ...) is denied by the MCP
  #   gate above, so mail access stays read-only.
  mcp :mail,
    transport: :stdio,
    command:   ENV.fetch("MAIL_MCP_COMMAND", "apple-mail-mcp")

  # NOTE: the read-only mail allow-list lives in the Permissions instance above
  # (mcp_allow: MAIL_READ_TOOLS). The `mcp_allow` macro is intentionally NOT used
  # here — when a Permissions instance is passed, the macro is ignored, so keeping
  # both would be misleading.

  # The skill teaches the model HOW to classify and how to shape the digest.
  skills :email_triage

  instructions <<~TXT
    You triage an Apple Mail inbox using the attached email_triage skill. Classify
    recent messages, compose a concise markdown digest of the threads that warrant
    the user's attention, and SAVE it to `inbox-digest.md` in the workspace using
    the write tool. You may read mail and write that one file — nothing else. Never
    send, delete, flag, or move mail (those tools are denied). Once the digest file
    is written, STOP: reply with a one-line confirmation and do not take further
    actions or re-scan the inbox.
  TXT
end
