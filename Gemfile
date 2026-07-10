# frozen_string_literal: true

source "https://rubygems.org"

# The harness. Pointed at the local checkout so we track the in-development API.
gem "nexo_ai", path: "../../maquina/nexo"

# Nexo composes ruby_llm-mcp for the `mcp` macro — it is a SOFT dependency of the
# gem (loaded lazily), so an app that attaches an MCP server must require it itself.
gem "ruby_llm-mcp"

# The `skills` macro loads SKILL.md packages via ruby_llm-skills — also a soft
# dependency, required here because this agent attaches the email_triage skill.
gem "ruby_llm-skills"
