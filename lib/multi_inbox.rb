# frozen_string_literal: true

# A Nexo Workflow that triages THREE email sources — Apple Mail (MCP), Gmail
# (IMAP) and HEY (CLI) — with one triage agent per source. Each source agent
# writes its digest fragment into the shared ./sandbox workspace; a merge agent
# then reads those fragments and writes the unified ./sandbox/inbox-digest.md.
#
# Reuses the LLM/Nexo config + SANDBOX_DIR from config.rb.
require "fileutils"
require_relative "config"      # RubyLLM/Nexo config, SANDBOX_DIR
require_relative "cli_sources" # HEY read-only CLI tools (+ optional gws Gmail)
require_relative "gmail_imap"  # Gmail read-only over IMAP (App Password, no gcloud)

# The Apple Mail READ tools AppleMailSource is allowed to invoke. Names must match
# the apple-mail-mcp server EXACTLY (the MCP gate fails closed); everything else it
# exposes (send/delete/flag/move) is denied.
MAIL_READ_TOOLS = %w[
  list_accounts list_mailboxes get_emails get_email search get_email_links get_email_attachment
].freeze

# Sandbox capabilities every triage agent gets: read/glob for the workspace plus
# write (to save its digest). Mode stays :read_only, so the MCP axis is fail-closed
# and shell is denied — write is the only capability granted beyond the defaults.
SANDBOX_WRITE = %i[read glob write].freeze

# --- Shared base for the per-source triage agents ---------------------------
# Identical except for HOW each reaches its inbox. Each runs a :local sandbox
# (rooted at SANDBOX_DIR when instantiated with cwd:) and may write its fragment
# there; mail access stays read-only.
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

  def chat(base: nil)
    chat = super
    tools = self.class.source_tools.map(&:new)
    chat.with_tools(*tools) unless tools.empty?
    chat
  end
end

# Apple Mail — reached through the apple-mail-mcp server, gated read-only. Same
# grant as the base, plus the read-only MCP allow-list.
class AppleMailSource < SourceAgent
  permissions Nexo::Permissions.new(mode: :read_only, allow: SANDBOX_WRITE, mcp_allow: MAIL_READ_TOOLS)
  mcp :mail, transport: :stdio, command: ENV.fetch("MAIL_MCP_COMMAND", "apple-mail-mcp")
end

# Gmail — reached read-only over IMAP with an App Password (no gcloud/gws needed).
# To use the `gws` OAuth CLI instead, swap in [CliSources::GmailUnread, CliSources::GmailRead].
class GmailSource < SourceAgent
  def self.source_tools = [GmailImap::List, GmailImap::Read]
end

# HEY — reached through the `hey` CLI via read-only tool wrappers.
class HeySource < SourceAgent
  def self.source_tools = [CliSources::HeyImbox, CliSources::HeyThread]
end

# --- The merge agent --------------------------------------------------------
# Inherits the shared triage config (model, :local sandbox + write, skill); it
# attaches no mail tools (source_tools defaults to []) and reads the per-source
# fragments handed to it in the prompt, writing ONE unified digest.
class MergeDigests < SourceAgent
  instructions <<~TXT
    You merge several per-source email triage digests into ONE unified digest.
    Pool the "Needs action" items across sources first, then the "FYI" items,
    tagging each line with its source, e.g. "[Gmail]". Apply the always-surface
    rules from the skill. Save the result to the file named in the prompt with the
    write tool, then confirm in one line.
  TXT
end

# --- The workflow -----------------------------------------------------------
class MultiInboxTriage < Nexo::Workflow
  # name => [agent class, fragment filename]
  SOURCES = {
    "Apple Mail" => [AppleMailSource, "apple-mail.md"],
    "Gmail"      => [GmailSource, "gmail.md"],
    "HEY"        => [HeySource, "hey.md"]
  }.freeze

  DIGEST_FILE = "inbox-digest.md"

  def call(_payload)
    FileUtils.mkdir_p(SANDBOX_DIR)

    fragments = SOURCES.keys.zip(fan_out_sources).to_h

    emit(:merging, sources: fragments.keys)
    MergeDigests.new(cwd: SANDBOX_DIR).prompt(merge_prompt(fragments), max_turns: 6) do |type, payload|
      forward_event("merge", type, payload)
    end

    digest_path = File.join(SANDBOX_DIR, DIGEST_FILE)
    merged = File.exist?(digest_path) ? File.read(digest_path) : "_Merge produced no #{DIGEST_FILE}._"
    artifact(DIGEST_FILE, content: merged)

    {sources: fragments.keys, bytes: merged.length}
  end

  private

  # Triage the three sources concurrently: their LLM round-trips (the bulk of the
  # wall-clock) overlap inside one async reactor, bounded to SOURCES.size in
  # flight. Results come back in submission order — SOURCES order — so the caller
  # can zip them straight back to their names. Each source writes a distinct
  # fragment file, so there's no write contention. Falls back to sequential when
  # the `async` gem isn't installed.
  def fan_out_sources
    Nexo.concurrent(max_in_flight: SOURCES.size) do |c|
      SOURCES.each { |name, (klass, file)| c.add { triage_source(name, klass, file) } }
    end
  rescue Nexo::MissingDependencyError => e
    emit(:async_unavailable, error: e.message)
    SOURCES.map { |name, (klass, file)| triage_source(name, klass, file) }
  end

  # Runs one source agent, which writes its fragment into SANDBOX_DIR; returns the
  # fragment text (read back from disk). A failing source degrades to a note.
  def triage_source(name, klass, file)
    emit(:source_started, source: name, file: file)
    agent = klass.new(cwd: SANDBOX_DIR)
    agent.prompt(
      "Triage this inbox per the skill, then save the digest to the file `#{file}` in the workspace.",
      max_turns: 30
    ) { |type, payload| forward_event(name, type, payload) }

    path = File.join(SANDBOX_DIR, file)
    fragment = File.exist?(path) ? File.read(path) : "### #{name}\n\n_No fragment written._"
    emit(:source_done, source: name, bytes: fragment.length)
    fragment
  rescue => e
    emit(:source_failed, source: name, error: e.message)
    "### #{name}\n\n_Triage failed: #{e.message}_"
  ensure
    agent&.close
  end

  # Mirror an agent event into the workflow log with a compact, source-tagged shape.
  def forward_event(source, type, payload)
    data =
      case type
      when :tool_call then {source: source, tool: payload.respond_to?(:name) ? payload.name : payload.to_s}
      when :tool_result then {source: source, result: payload.to_s[0, 200]}
      else {source: source, info: payload.to_s[0, 200]}
      end
    emit(:"agent_#{type}", **data)
  end

  def merge_prompt(fragments)
    sections = fragments.map { |name, frag| "### Source: #{name}\n\n#{frag}" }.join("\n\n---\n\n")
    "Merge these per-source triage digests into one unified digest and save it to " \
      "`#{DIGEST_FILE}`:\n\n#{sections}"
  end
end
