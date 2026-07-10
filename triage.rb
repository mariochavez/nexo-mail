# frozen_string_literal: true

# Run the Apple Mail triage agent once and print the digest, with verbose logging
# of every step: model turns, each MCP tool call + its result, and timing.
#
#   bundle install
#   ruby triage.rb               # our step logs (tool calls + results + timing)
#   DEBUG=1 ruby triage.rb       # + our own debug-level detail
#   RUBYLLM_WIRE=1 ruby triage.rb # + ruby_llm's raw HTTP/MCP wire trace (very noisy)
#
# Env overrides (all optional — defaults target the local setup):
#   LLM_API_BASE     default http://127.0.0.1:8090/v1
#   LLM_API_KEY      default local-ai
#   LLM_MODEL        default Ornith-1.0-9B-4bit
#   MAIL_MCP_COMMAND default apple-mail-mcp
require "bundler/setup"
require "logger"

# Loads nexo + ruby_llm and applies the agent's own RubyLLM.configure (base URL/key).
require_relative "lib/mail_triage_agent"

# ruby_llm's OWN logger. Keep it at WARN by default: at DEBUG/INFO it dumps the
# entire outgoing request body every turn — including the full tool-definition
# JSON for all MCP tools — which floods the console and hides our own step logs.
# Set RUBYLLM_WIRE=1 only when you actually want that raw HTTP/MCP wire trace.
# (Runs after the require above so RubyLLM is loaded and this wins over its defaults.)
RubyLLM.configure do |config|
  config.logger = Logger.new($stdout)
  config.logger.level = ENV["RUBYLLM_WIRE"] ? Logger::DEBUG : Logger::WARN
end

log = Logger.new($stdout)
log.formatter = ->(sev, time, _prog, msg) { "[#{time.strftime("%H:%M:%S")}] #{sev.ljust(5)} #{msg}\n" }

# Truncate long tool payloads so the log stays readable.
clip = ->(obj, n = 500) do
  s = obj.is_a?(String) ? obj : obj.inspect
  s.length > n ? "#{s[0, n]}… (#{s.length} chars)" : s
end

turn = 0
started = nil

# on_event fires for every step in the agent loop: (:tool_call | :tool_result | :done).
observe = lambda do |type, payload|
  case type
  when :tool_call
    turn += 1
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    name = payload.respond_to?(:name) ? payload.name : payload
    args = payload.respond_to?(:arguments) ? payload.arguments : nil
    log.info("→ tool_call ##{turn}: #{name}  args=#{clip.call(args)}")
  when :tool_result
    ms = started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round : nil
    content = payload.respond_to?(:content) ? payload.content : payload
    log.info("← tool_result ##{turn} (#{ms}ms): #{clip.call(content)}")
  when :done
    resp = payload
    if resp.respond_to?(:input_tokens)
      log.info("✓ done: model=#{resp.model_id} in=#{resp.input_tokens} out=#{resp.output_tokens}")
    else
      log.info("✓ done")
    end
  end
end

log.info("Starting MailTriage — model=#{MailTriage.model} base=#{ENV.fetch("LLM_API_BASE", "http://127.0.0.1:8090/v1")}")
log.info("Allowed MCP tools: #{MailTriage.mcp_allow.join(", ")}")

agent = MailTriage.new
begin
  wall = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  log.info("Connecting to apple-mail-mcp and prompting the model…")

  response = agent.prompt(
    "Classify today's inbox and produce a markdown digest of the threads worth my attention.",
    &observe
  )

  total = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall).round(1)
  log.info("Finished in #{total}s after #{turn} tool call(s)")

  puts "\n" + ("=" * 60)
  puts response.content
  puts "=" * 60
rescue => e
  log.error("#{e.class}: #{e.message}")
  log.error(e.backtrace.first(5).join("\n")) if e.backtrace
  raise
ensure
  agent.close # tear down the stdio MCP subprocess
  log.info("MCP subprocess closed.")
end
