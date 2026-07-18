# frozen_string_literal: true

module NexoMail
  # Per-run archive of a triage's artifacts. Every run drops its deliverables
  # (digest.json, dashboard.html, inbox-digest.md) into a timestamped directory
  # under Config.snapshots_dir; `nexo-triage --prune-snapshots` trims the history
  # to the newest N. Pure file bookkeeping — no model, no network.
  module Snapshots
    # A snapshot directory name is a filesystem-safe UTC timestamp; sorting the
    # names lexicographically therefore sorts them chronologically.
    STAMP = "%Y%m%dT%H%M%SZ"

    module_function

    def dir = Config.snapshots_dir

    # Write the given files into a fresh timestamped snapshot dir and return its
    # path. +files+ is a { "name" => content } hash. +at+ lets a caller pin the
    # timestamp (tests); defaults to now.
    def create(files, at: Time.now.utc)
      dest = File.join(dir, at.strftime(STAMP))
      FileUtils.mkdir_p(dest)
      files.each { |name, content| File.write(File.join(dest, name), content.to_s) }
      dest
    end

    # All snapshot directories, newest first.
    def list
      return [] unless File.directory?(dir)

      Dir.children(dir)
        .map { |name| File.join(dir, name) }
        .select { |path| File.directory?(path) }
        .sort
        .reverse
    end

    # Keep the newest +keep+ snapshots, delete the rest. Returns the paths removed.
    # A non-positive +keep+ is treated as "keep 0" (prune everything).
    def prune(keep: Config.snapshots_keep)
      keep = [keep.to_i, 0].max
      removed = list.drop(keep)
      removed.each { |path| FileUtils.rm_rf(path) }
      removed
    end
  end
end
