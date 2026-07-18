# frozen_string_literal: true

module NexoMail
  module Tools
    # Archives the current run's artifacts from the workspace into a fresh
    # timestamped snapshot directory. Thin: the agent decides to call it; this just
    # copies the known deliverables that exist. Returns the snapshot path.
    class ArchiveRun < RubyLLM::Tool
      description "Archive this run's artifacts (digest.json, dashboard.html, inbox-digest.md) into a new timestamped snapshot directory. Returns the snapshot path."

      ARTIFACTS = %w[digest.json dashboard.html inbox-digest.md].freeze

      def execute
        files = ARTIFACTS.each_with_object({}) do |name, acc|
          path = File.join(Config.sandbox_dir, name)
          acc[name] = File.read(path) if File.exist?(path)
        end
        return {error: "no artifacts found in workspace to archive"} if files.empty?

        dest = Snapshots.create(files)
        {snapshot: dest, files: files.keys}
      rescue => e
        {error: e.message}
      end
    end
  end
end
