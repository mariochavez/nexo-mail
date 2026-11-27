# frozen_string_literal: true

module NexoMail
  module Agents
    # What every agent in the pipeline shares: the :local sandbox rooted at the
    # workspace (via cwd:), read/glob/write and nothing else, the `today` tool, the
    # user's prompt fragments, and the model injected at runtime. What an agent is
    # FOR — its skills, instructions and tools — is declared by each subclass.
    class Base < Nexo::Agent
      sandbox :local
      permissions Nexo::Permissions.new(mode: :read_only, allow: NexoMail::SANDBOX_WRITE)

      # Attached to EVERY agent, on top of whatever a subclass declares with `tools`.
      # A model has no notion of today, and that is not a stylistic problem: a run
      # generated on 2026-08-20 produced a schedule of 2026-06-18 / 2026-07-17 /
      # 2026-07-23 — every appointment already past — and counted June charges as
      # current. Declared through Nexo's macro so Nexo knows the tool: under
      # strict_tools (see CLI) a tool it did not attach is refused.
      tools Tools::Today

      # Injects the active model onto every agent class. Called by the CLI after
      # config is loaded, before any agent is instantiated. The classes are found,
      # not listed: every constant under Agents is loaded and each Base subclass
      # configured, so a new agent class needs no entry anywhere.
      def self.configure_model!(model)
        Agents.constants.each { |name| Agents.const_get(name) }
        [self, *descendants].each do |klass|
          klass.model model.model
          klass.provider model.provider.to_sym
          klass.assume_model_exists true
        end
      end

      # Every loaded subclass, however deep.
      def self.descendants = subclasses.flat_map { |klass| [klass, *klass.descendants] }

      # The prompt-fragment key (<prompts_dir>/<key>.md) appended to this agent's
      # instructions. nil on the base; concrete agents override.
      def self.prompt_key = nil

      # Instance-level view of the prompt key #chat wires. Defaults to the class
      # macro; EmailSource overrides it to read a per-instance descriptor.
      def prompt_key = self.class.prompt_key

      # Preflight availability check. Returns nil when the agent can run, or a short
      # reason string when it cannot (missing binary/credentials). The workflow skips
      # unavailable sources. Always available here; subclasses override.
      def self.availability = nil

      # Pure-Ruby PATH lookup (no shell): true when +cmd+ is an executable on PATH.
      def self.command?(cmd)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, cmd)
          File.file?(path) && File.executable?(path)
        end
      end

      # Append user prompt fragments on top of Nexo's normal wiring (with_instructions
      # is additive). A `common` fragment applies to every agent, plus a per-agent one.
      def chat(base: nil)
        chat = super
        [Config.prompt_fragment("common"), Config.prompt_fragment(prompt_key)]
          .compact.each { |fragment| chat.with_instructions(fragment, append: true) }
        chat
      end
    end
  end
end
