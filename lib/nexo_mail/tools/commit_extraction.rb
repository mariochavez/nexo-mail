# frozen_string_literal: true

module NexoMail
  module Tools
    # Merges the items a source agent extracted THIS run into that inbox's ledger and
    # writes the full extraction file the rest of the pipeline reads.
    #
    # Thin, and deliberately so: the agent decided what each message is and how far
    # back the briefing reaches; this only does the part that must not be approximate
    # — upsert by id, mark the listed mail as triaged, write the merged array. It is
    # also the ONLY thing that advances the ledger, so an agent that never calls it
    # leaves the mail to be offered again on the next run.
    class CommitExtraction < RubyLLM::Tool
      description <<~DESC.strip
        Save this run's extraction. Call it ONCE, last, after writing the JSON array of
        the items you extracted from the NEW mail to your `*.new.json` file.

        It merges those items with what earlier runs already extracted from this inbox
        (same `id` replaces the earlier item), marks the mail you were listed as
        triaged so later runs skip it, and writes the inbox's full extraction file.

        Pass `file` (the `*.new.json` you wrote — an empty array `[]` when nothing new
        arrived) and `keep_since` (the ISO date your run window starts): items received
        before it are left out of the extraction file, though they stay on record.
        Pass `keep_by_lane` to give a lane its own cutoff instead — e.g. reading kept
        30 days, conversations 90.

        A sender the reader has fixed to a lane gets that lane whatever you wrote.
      DESC

      parameters do
        string :file, description: "The *.new.json file you wrote in the workspace"
        string :keep_since, description: "ISO date the run window starts; older items are left out", required: false
        object :keep_by_lane, description: "ISO date per lane, overriding keep_since for that lane", required: false do
          SenderMemory::LANES.each { |lane| string lane.to_sym, required: false }
        end
      end

      # Remove a source's extraction file (and any half-written `*.new.json`) from the
      # workspace before its agent runs. The file is only a VIEW of the ledger, rebuilt
      # by every commit — but left in place, a source agent finds the previous run's
      # copy, takes it for "what is already on record", and trims its own output to
      # match. Measured: an Apple Mail agent listed 48 new messages, read the stale
      # 45-item file, and committed 7.
      def self.clear(target)
        [target, Ledger.inbox_file(target)].each { |name| FileUtils.rm_f(File.join(Config.sandbox_dir, File.basename(name))) }
      end

      def execute(file:, keep_since: nil, keep_by_lane: nil)
        target = target_for(file)
        return JSON.generate(error: "unknown file #{file.inspect} — expected one of: #{inboxes.keys.join(", ")}") unless target

        inbox = File.join(Config.sandbox_dir, File.basename(file))
        return JSON.generate(error: "#{File.basename(file)} does not exist — write your items to it first") unless File.exist?(inbox)

        items = JSON.parse(File.read(inbox))
        return JSON.generate(error: "#{File.basename(file)} must hold a JSON array of items") unless items.is_a?(Array)

        ledger = Ledger.for_file(target)
        items.grep(Hash).each { |item| (lane = SenderMemory.fixed(item["sender_email"])) && item["lane"] = lane }
        # Counted before the commit makes them known: only a first filing teaches
        # the sender memory, not a thread that came back.
        first_filed = items.grep(Hash).reject { |item| ledger.known?(item) }
        kept = ledger.commit(items, keep_since: keep_since, keep_by_lane: keep_by_lane)
        SenderMemory.learn(first_filed)
        # One item per line: the next stage reads this file through a line-windowed
        # read tool, and pretty-printing turned 204 items into 2,927 lines — six
        # round trips to read what fits in one.
        File.write(File.join(Config.sandbox_dir, target), "[\n#{kept.map { |item| JSON.generate(item) }.join(",\n")}\n]\n")
        # Gone once merged, so the next run writes a fresh file instead of paying a
        # round trip to read this one before it may overwrite it.
        FileUtils.rm_f(inbox)

        JSON.generate(written: target, new_items: items.size, items_in_file: kept.size, items_on_record: ledger.size)
      rescue JSON::ParserError => e
        JSON.generate(error: "#{File.basename(file)} is not valid JSON (#{e.message[0, 120]}) — rewrite it and call again")
      rescue => e
        JSON.generate(error: e.message)
      end

      private

      # "hey.new.json" => "hey.json", for every source in the catalog. Anything else
      # is refused: this tool writes only the extraction files the pipeline defines.
      def inboxes = Sources.all.to_h { |source| [Ledger.inbox_file(source.file), source.file] }

      def target_for(file) = inboxes[File.basename(file.to_s)]
    end
  end
end
