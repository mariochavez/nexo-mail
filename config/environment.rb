# frozen_string_literal: true

# Boot the Nexo Mail Agent: load gems, configure the LLM + skills, define shared
# constants, and set up Zeitwerk autoloading. Require this once to boot the app.

ROOT = File.expand_path("..", __dir__)
ENV["BUNDLE_GEMFILE"] ||= File.join(ROOT, "Gemfile")

require "bundler/setup"
require "logger"
require "fileutils"
require "open3"
require "json"
require "net/imap"
require "date"
require "zeitwerk"
require "nexo"
require "ruby_llm"
require "ruby_llm/mcp"

# --- Shared constants -------------------------------------------------------
# Scratch workspace: agents run a :local sandbox rooted here, so every file they
# write (per-source fragments + the digest) is fenced to this one directory.
SANDBOX_DIR = File.join(ROOT, "sandbox")

# Sandbox capabilities every triage agent gets: read/glob + write (to save its
# digest). Mode stays :read_only, so the MCP axis is fail-closed and shell denied.
SANDBOX_WRITE = %i[read glob write].freeze

# Apple Mail READ tools AppleMailSource may invoke; names must match the
# apple-mail-mcp server exactly (the MCP gate fails closed).
MAIL_READ_TOOLS = %w[
  list_accounts list_mailboxes get_emails get_email search get_email_links get_email_attachment
].freeze

# --- Logging ----------------------------------------------------------------
# ruby_llm + ruby_llm-mcp are chatty; silence them so the styled runner output
# stays clean. RUBYLLM_WIRE=1 turns the raw HTTP/MCP trace back on.
QUIET_LOG = Logger.new(ENV["RUBYLLM_WIRE"] ? $stdout : File::NULL)
QUIET_LOG.level = ENV["RUBYLLM_WIRE"] ? Logger::DEBUG : Logger::FATAL

# --- LLM wiring: Ollama (OpenAI-compatible /v1) -----------------------------
RubyLLM.configure do |config|
  config.ollama_api_base = ENV.fetch("LLM_API_BASE", "http://localhost:11434/v1")
  config.ollama_api_key = ENV["LLM_API_KEY"] if ENV["LLM_API_KEY"]
  config.logger = QUIET_LOG
end
if RubyLLM::MCP.respond_to?(:configure)
  RubyLLM::MCP.configure { |c| c.logger = QUIET_LOG }
elsif RubyLLM::MCP.respond_to?(:config)
  RubyLLM::MCP.config.logger = QUIET_LOG
end

# Skills live in app/skills (Rails-like); resolve `skills :email_triage` from there.
Nexo.configure { |config| config.skills_path = File.join(ROOT, "app", "skills") }

# --- Autoloading (Rails-like) -----------------------------------------------
# Each app/ subdir is an autoload ROOT, so classes are top-level (SourceAgent,
# HeyImbox, MultiInboxTriage) — matching Nexo's own app/agents / app/workflows
# convention. Zeitwerk loads each class on first reference; no manual requires.
loader = Zeitwerk::Loader.new
loader.push_dir(File.join(ROOT, "app", "agents"))
loader.push_dir(File.join(ROOT, "app", "tools"))
loader.push_dir(File.join(ROOT, "app", "workflows"))
loader.setup
