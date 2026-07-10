# frozen_string_literal: true

# Triage Apple Mail + Gmail + HEY in one run and write a unified inbox-digest.md
# into ./sandbox — with a styled terminal UI (Charm for Ruby).
#
# Prerequisites (one-time):
#   * apple-mail-mcp on PATH (indexed)
#   * Gmail:  export GMAIL_ADDRESS + GMAIL_APP_PASSWORD  (read-only IMAP)
#   * HEY:    hey auth login
#   * LLM_API_KEY exported (for glm-5.2:cloud via Ollama Cloud) + `ollama signin`
#
#   ruby triage.rb
#   RUBYLLM_WIRE=1 ruby triage.rb   # show the raw ruby_llm/MCP logs (debugging)
require "bundler/setup"
require "io/console"
require "lipgloss"
require "glamour"
require_relative "lib/multi_inbox"

# --- Styles -----------------------------------------------------------------
BRAND = "#7D56F4"
GREEN = "#04B575"
AMBER = "#FFB454"
GRAY  = "#6C6C6C"

module UI
  module_function

  def header = Lipgloss::Style.new.bold(true).foreground("#FAFAFA").background(BRAND).padding(0, 2)
  def brand  = Lipgloss::Style.new.foreground(BRAND).bold(true)
  def dim    = Lipgloss::Style.new.foreground(GRAY)
  def ok     = Lipgloss::Style.new.foreground(GREEN).bold(true)
  def bad    = Lipgloss::Style.new.foreground(AMBER).bold(true)

  def term_width = (IO.console&.winsize&.last || 80)

  def clock(seconds)
    format("%02d:%02d", (seconds / 60).to_i, (seconds % 60).to_i)
  end

  def duration(ms)
    ms = ms.to_i
    ms < 1000 ? "#{ms}ms" : format("%.1fs", ms / 1000.0)
  end
end

SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

puts
puts UI.header.render("Nexo Mail Agent — Apple Mail · Gmail · HEY")
puts

# --- Run the workflow in the background; animate a spinner + clock -----------
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = nil
error = nil
worker = Thread.new do
  result = MultiInboxTriage.run
rescue => e
  error = e
end

frame = 0
while worker.alive?
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  print "\r#{UI.brand.render(SPINNER[frame % SPINNER.size])} " \
        "Triaging 3 inboxes…  #{UI.dim.render("elapsed #{UI.clock(elapsed)}")}   "
  $stdout.flush
  frame += 1
  sleep 0.1
end
worker.join
print "\r\e[K" # clear the spinner line

if error
  puts UI.bad.render("✗ Run failed: #{error.class}: #{error.message}")
  raise error
end

run = result
total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

# --- Per-source timing, read back from the workflow event log ---------------
results = {}
Nexo::Workflow.logs(run.id) do |ev|
  d = ev["data"] || {}
  case ev["type"]
  when "source_done"   then results[d["source"]] = {ok: true, ms: d["ms"]}
  when "source_failed" then results[d["source"]] = {ok: false, ms: d["ms"], error: d["error"]}
  end
end

MultiInboxTriage::SOURCES.each_key do |name|
  r = results[name]
  if r.nil?
    puts "  #{UI.dim.render("• #{name} — no result")}"
  elsif r[:ok]
    puts "  #{UI.ok.render("✓")} #{UI.brand.render(name.ljust(11))} #{UI.dim.render(UI.duration(r[:ms]))}"
  else
    puts "  #{UI.bad.render("✗")} #{UI.brand.render(name.ljust(11))} " \
         "#{UI.dim.render(UI.duration(r[:ms]))}  #{UI.bad.render(r[:error].to_s[0, 60])}"
  end
end
puts "  #{UI.dim.render("─" * 24)}"
puts "  #{UI.brand.render("total".ljust(13))}#{UI.dim.render(UI.clock(total))}"

# --- Render the unified digest with Glamour ---------------------------------
art = run.artifacts.find { |a| (a["name"] || a[:name]) == "inbox-digest.md" }
digest = art && (art["content"] || art[:content])

puts
if digest && !digest.strip.empty?
  puts Glamour.render(digest, style: "dark", width: [UI.term_width, 100].min)
  puts UI.dim.render("Saved to #{File.join(SANDBOX_DIR, "inbox-digest.md")}")
else
  puts UI.bad.render("No digest produced (run status: #{run.status}).")
end
