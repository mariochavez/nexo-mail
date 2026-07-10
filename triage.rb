# frozen_string_literal: true

# Triage Apple Mail + Gmail + HEY in one run and write a unified inbox-digest.md
# into ./sandbox.
#
# Prerequisites (one-time):
#   * apple-mail-mcp on PATH (indexed)
#   * Gmail:  export GMAIL_ADDRESS + GMAIL_APP_PASSWORD  (read-only IMAP)
#   * HEY:    hey auth login
#   * LLM_API_KEY exported (for glm-5.2:cloud via Ollama Cloud) + `ollama signin`
#
#   ruby triage.rb
require "bundler/setup"
require_relative "lib/multi_inbox"

puts "Triaging Apple Mail + Gmail + HEY…"
run = MultiInboxTriage.run

puts "\nRun #{run.id} -> #{run.status}"

# Interleaved event log (per-source tool calls + merge), newest last.
Nexo::Workflow.logs(run.id) do |ev|
  puts "  [#{ev["type"]}] #{(ev["data"] || {}).to_json}"
end

art = run.artifacts.find { |a| (a["name"] || a[:name]) == "inbox-digest.md" }
if art
  content = art["content"] || art[:content]
  puts "\n" + ("=" * 60)
  puts content
  puts "=" * 60
  puts "\nDigest: #{File.join(SANDBOX_DIR, "inbox-digest.md")}"
else
  warn "No digest artifact produced (run status: #{run.status})."
end
