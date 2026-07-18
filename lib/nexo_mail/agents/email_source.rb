# frozen_string_literal: true

module NexoMail
  module Agents
    # One data-driven triage agent for every tool-based email source (Gmail, HEY,
    # and any future IMAP/CLI-style service). It IS a SourceAgent — same model,
    # :local sandbox, read-only permissions, extraction skills and triage prompt —
    # but takes its per-source inputs from a Sources::Descriptor at construction
    # instead of hardcoding them as a subclass. The descriptor supplies the tools
    # that reach the inbox and the prompt-fragment key; SourceAgent#chat reads both
    # through the instance readers overridden below.
    #
    # MCP-backed sources (Apple Mail) can't use this — the `mcp` macro is
    # class-level — so they stay their own thin subclass. Adding a tool-based
    # service, though, is now just a descriptor in NexoMail::Sources.
    class EmailSource < SourceAgent
      attr_reader :descriptor

      def initialize(descriptor:, cwd:)
        @descriptor = descriptor
        super(cwd: cwd)
      end

      def source_tools = descriptor.tools
      def prompt_key = descriptor.prompt_key
    end
  end
end
