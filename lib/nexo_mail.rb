# frozen_string_literal: true

# Nexo Mail Agent — triage Apple Mail, Gmail & HEY into one prioritized digest.
#
# This file boots the library: it requires dependencies and sets up Zeitwerk
# autoloading. It deliberately does NOT configure RubyLLM/Nexo or read any config
# — a library must not mutate global state on require. Runtime configuration
# happens in NexoMail::CLI.run, after the XDG config is loaded.

require "logger"
require "fileutils"
require "open3"
require "json"
require "net/imap"
require "date"
require "toml-rb"
require "zeitwerk"
require "nexo"
require "ruby_llm"
require "ruby_llm/mcp"

require_relative "nexo_mail/version"

module NexoMail
  class Error < StandardError; end

  # The gem's root and its bundled (packaged) asset directory.
  ROOT = File.expand_path("..", __dir__)
  DATA_DIR = File.join(ROOT, "data")

  # Sandbox capabilities every triage agent gets: read/glob for the workspace plus
  # write (to save its digest). Mode stays :read_only, so the MCP axis is fail-closed
  # and shell is denied — write is the only capability granted beyond the defaults.
  SANDBOX_WRITE = %i[read glob write].freeze

  # Apple Mail READ tools AppleMailSource may invoke; names must match the
  # apple-mail-mcp server exactly (the MCP gate fails closed).
  MAIL_READ_TOOLS = %w[
    list_accounts list_mailboxes get_emails get_email search get_email_links get_email_attachment
  ].freeze
end

# One Zeitwerk root at lib/, so lib/nexo_mail/agents/source_agent.rb maps to
# NexoMail::Agents::SourceAgent, etc. Default inflections cover every filename here
# (cli_reader → CliReader, gmail_imap → GmailImap, gws_gmail_read → GwsGmailRead).
loader = Zeitwerk::Loader.for_gem
loader.ignore("#{__dir__}/nexo_mail/version.rb") # already required above
loader.inflector.inflect("cli" => "CLI") # cli.rb defines NexoMail::CLI (not Cli)
loader.setup
