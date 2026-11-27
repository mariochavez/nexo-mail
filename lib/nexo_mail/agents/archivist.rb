# frozen_string_literal: true

module NexoMail
  module Agents
    # Keeps the run history tidy. Inherits the shared triage config; attaches the
    # snapshot tools instead of mail tools. Driven by the snapshot_keeper skill, it
    # archives a finished run's artifacts and prunes old snapshots to the requested
    # retention — the tools do the bounded file work, the agent decides the calls.
    class Archivist < SourceAgent
      # Reset inherited extraction skills — the archivist only manages snapshots.
      @skills = %i[snapshot_keeper]

      # Both tools change files on the host (the snapshots directory), so they are
      # declared as :write. Nexo's permission gate then decides every call, exactly as
      # it does for its own write tool: allowed here because this agent's permissions
      # grant :write, refused for any agent whose permissions do not.
      tools Tools::ArchiveRun, Tools::PruneSnapshots, capability: :write
      def self.prompt_key = "archivist"

      instructions <<~TXT
        You keep the run history tidy with the archive_run and prune_snapshots tools,
        following the snapshot_keeper skill. Do exactly what the prompt asks —
        archive-then-prune after a run, or prune only — and confirm the result in one
        line. Nothing else.
      TXT
    end
  end
end
