# frozen_string_literal: true

source "https://rubygems.org"

# The agent harness (published on RubyGems).
gem "nexo_ai", "~> 0.7"

# Nexo composes ruby_llm-mcp for the `mcp` macro — it is a SOFT dependency of the
# gem (loaded lazily), so an app that attaches an MCP server must require it itself.
gem "ruby_llm-mcp"

# The `skills` macro loads SKILL.md packages via ruby_llm-skills — also a soft
# dependency, required here because this agent attaches the email_triage skill.
gem "ruby_llm-skills"

# Read-only Gmail over IMAP (App Password). In Ruby 3.4+/4.0 net-imap is no longer
# a default gem, so it must be declared explicitly.
gem "net-imap"

# Opt-in async fan-out: Nexo.concurrent runs the three source agents concurrently
# (their LLM round-trips overlap). Soft dependency — Nexo only needs it when used.
gem "async", "~> 2.0"
