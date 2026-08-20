# frozen_string_literal: true

module NexoMail
  module Agents
    # Shared base for the per-source triage agents. They're identical except for
    # HOW each reaches its inbox (which tools it attaches). Each runs a :local
    # sandbox (rooted at Config.sandbox_dir via cwd:) and may write its digest
    # fragment there; mail access stays read-only. The model/provider is injected
    # at runtime from the selected config model (see .configure_model!).
    class SourceAgent < Nexo::Agent
      sandbox :local
      permissions Nexo::Permissions.new(mode: :read_only, allow: NexoMail::SANDBOX_WRITE)
      skills :email_triage, :financial_summary, :interest_radar

      instructions <<~TXT
        You triage ONE email inbox and EXTRACT it into structured JSON, following the
        attached skills: read recent messages, classify each into action/fyi/noise,
        and pull the entities that matter — payments & charges (financial_summary),
        meetings, people, and newsletter topics (interest_radar). When the prompt
        names a file, write a single JSON array of item objects to it with the write
        tool, then confirm in one line. No prose in the file — just the array. Work
        with the mail-reading tools you were given plus the write tool. Read-only:
        never send, delete, or modify mail.
      TXT

      # Inject the active model onto every triage class (base + concrete sources +
      # synthesis), so the `inherited`-copy timing is a non-issue. Called by the CLI
      # after config is loaded, before any agent is instantiated.
      def self.configure_model!(model)
        [SourceAgent, EmailSource, AppleMailSource, Synthesize, Publisher, Archivist].each do |klass|
          klass.model model.model
          klass.provider model.provider.to_sym
          klass.assume_model_exists true
        end
      end

      # Plain (non-MCP) RubyLLM tool classes to attach for this source; MCP-backed
      # sources leave this empty and use the `mcp` macro instead.
      def self.source_tools = []

      # Attached to EVERY agent, on top of whatever the source declares. A model has
      # no notion of today, and that is not a stylistic problem: a run generated on
      # 2026-08-20 produced a schedule of 2026-06-18 / 2026-07-17 / 2026-07-23 —
      # every appointment already past — and counted June charges as current.
      def self.common_tools = [Tools::Today]

      # The prompt-fragment key (<prompts_dir>/<key>.md) appended to this agent's
      # instructions. nil on the base; concrete sources override.
      def self.prompt_key = nil

      # Instance-level views of the two per-source inputs #chat wires. They default
      # to the class macros (so AppleMailSource/Synthesize/Publisher/Archivist keep
      # their class-level declarations), but EmailSource overrides them to read a
      # per-instance descriptor — that's how one class serves many tool-based sources.
      def source_tools = self.class.source_tools
      def prompt_key = self.class.prompt_key

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
        tools = (source_tools + self.class.common_tools).uniq.map(&:new)
        chat.with_tools(*tools) unless tools.empty?
        [Config.prompt_fragment("common"), Config.prompt_fragment(prompt_key)]
          .compact.each { |fragment| chat.with_instructions(fragment, append: true) }
        chat
      end
    end
  end
end
