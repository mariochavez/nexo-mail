# frozen_string_literal: true

module NexoMail
  module Tools
    # Deletes the oldest run snapshots, keeping the newest +keep+. The deletion is
    # bounded to the snapshots directory (Snapshots.prune only ever removes its own
    # timestamped subdirs), so an agent driving this can never reach anything else.
    class PruneSnapshots < RubyLLM::Tool
      description "Delete old run snapshots, keeping the newest `keep`. Returns how many were kept and which were removed. Bounded to the snapshots directory."
      param :keep, type: :integer, required: false, desc: "How many of the newest snapshots to keep (default from config)"

      def execute(keep: nil)
        keep = Config.snapshots_keep if keep.nil?
        before = Snapshots.list.size
        removed = Snapshots.prune(keep: keep)
        {kept: before - removed.size, removed: removed.map { |p| File.basename(p) }, dir: Snapshots.dir}
      rescue => e
        {error: e.message}
      end
    end
  end
end
