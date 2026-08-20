# frozen_string_literal: true

require_relative "lib/nexo_mail/version"

Gem::Specification.new do |spec|
  spec.name = "nexo_mail"
  spec.version = NexoMail::VERSION
  spec.authors = ["Mario Chavez"]
  spec.summary = "Read your email and get a short, prioritized digest of what needs your attention."
  spec.description = "Nexo Mail Agent reads your inbox and hands you one concise digest — what " \
    "needs action, what's worth knowing, and what's just noise — so you can skip the scroll and " \
    "act on what matters. It covers your Apple Mail, Gmail, and HEY mail, runs locally and " \
    "read-only, and uses the AI model you choose."
  spec.license = "MIT"
  spec.homepage = "https://github.com/mariochavez/nexo_mail"
  spec.required_ruby_version = ">= 3.3"

  # The `*.md` glob picks up AGENTS.md, which is a symlink to .claude/CLAUDE.md —
  # repo furniture for coding agents, whose target is deliberately not packaged. A
  # symlink whose target is absent ships as a dangling link (and `gem build` says so
  # on every build), so drop symlinks outright rather than naming this one: any
  # future link into an unpackaged path is the same bug.
  spec.files = Dir["lib/**/*.rb", "data/**/*", "*.md", "LICENSE*"].reject { |f| File.symlink?(f) }
  spec.bindir = "exe"
  spec.executables = ["nexo-triage"]
  spec.require_paths = ["lib"]

  # Agent harness + LLM stack.
  spec.add_dependency "nexo_ai", "~> 0.11"
  spec.add_dependency "ruby_llm-mcp"
  spec.add_dependency "ruby_llm-skills"
  spec.add_dependency "zeitwerk"

  # Gmail over IMAP (net-imap is no longer default in Ruby 3.4+/4.0).
  spec.add_dependency "net-imap"

  # Config parsing.
  spec.add_dependency "toml-rb"

  # Concurrent source fan-out.
  spec.add_dependency "async", "~> 2.0"

  # Terminal UI (Charm for Ruby).
  spec.add_dependency "lipgloss"
  spec.add_dependency "glamour"
end
