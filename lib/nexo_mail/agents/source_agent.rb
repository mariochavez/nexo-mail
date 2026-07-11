# frozen_string_literal: true

module NexoMail
  module Agents
    # Shared base for the per-source triage agents. They're identical except for
    # HOW each reaches its inbox (which tools it attaches). Each runs a :local
    # sandbox (rooted at Config.sandbox_dir via cwd:) and may write its digest
    # fragment there; mail access stays read-only. The model/provider is injected
    # at runtime from the selected config model (see .configure_model!).
    class SourceAgent < Nexo::Agent
      sandbox     :local
      permissions Nexo::Permissions.new(mode: :read_only, allow: NexoMail::SANDBOX_WRITE)
      skills      :email_triage

      instructions <<~TXT
        You triage ONE email inbox with the attached email_triage skill: read recent
        messages, classify them, and compose the digest. When the prompt names a file,
        save the digest there with the write tool and confirm in one line. Work with
        the mail-reading tools you were given plus the write tool.
      TXT

      # Inject the active model onto every triage class (base + concrete sources +
      # merge), so the `inherited`-copy timing is a non-issue. Called by the CLI
      # after config is loaded, before any agent is instantiated.
      def self.configure_model!(model)
        [SourceAgent, AppleMailSource, GmailSource, HeySource, MergeDigests].each do |klass|
          klass.model model.model
          klass.provider model.provider.to_sym
          klass.assume_model_exists true
        end
      end

      # Plain (non-MCP) RubyLLM tool classes to attach for this source; MCP-backed
      # sources leave this empty and use the `mcp` macro instead.
      def self.source_tools = []

      # The prompt-fragment key (<prompts_dir>/<key>.md) appended to this agent's
      # instructions. nil on the base; concrete sources override.
      def self.prompt_key = nil

      # Preflight availability check. Returns nil when the source can run, or a short
      # reason string when it cannot (missing binary/credentials). The workflow skips
      # unavailable sources. Base is always available; subclasses override.
      def self.availability = nil

      # Pure-Ruby PATH lookup (no shell): true when +cmd+ is an executable on PATH.
      def self.command?(cmd)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, cmd)
          File.file?(path) && File.executable?(path)
        end
      end

      # Attach the source's tools and append user prompt fragments on top of Nexo's
      # normal wiring (super applies instructions + skill; with_tools/with_instructions
      # are additive). A `common` fragment applies to every agent, plus a per-agent one.
      def chat(base: nil)
        chat = super
        tools = self.class.source_tools.map(&:new)
        chat.with_tools(*tools) unless tools.empty?
        [Config.prompt_fragment("common"), Config.prompt_fragment(self.class.prompt_key)]
          .compact.each { |fragment| chat.with_instructions(fragment, append: true) }
        chat
      end
    end
  end
end
