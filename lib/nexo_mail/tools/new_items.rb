# frozen_string_literal: true

module NexoMail
  module Tools
    # The items triaged since the digest was last saved — what an update is built
    # from, in place of every extraction file.
    #
    # Read-only bookkeeping: it reports what the ledgers hold as pending and labels
    # each item with the inbox it came from. Handing them out does not mark them
    # digested; CommitDigest does, so a builder that stops halfway is handed the same
    # items next run.
    class NewItems < RubyLLM::Tool
      description <<~DESC.strip
        The mail triaged since the digest was last saved, as JSON. Read-only.

        Returns `mode`:
        - "update": `items` holds every extraction item `digest.json` does not
          reflect yet, each labelled with its `source`. An empty list means no new
          mail — the digest only needs rolling forward to today.
        - "full": there is no digest to update. Build it from the extraction files
          the prompt names instead; `items` is not returned.
      DESC

      def execute
        return JSON.generate(mode: "full", note: "no digest to update — build it from the extraction files") if DigestFile.plan == :full

        items = Sources.all.flat_map do |source|
          Ledger.for_file(source.file).take_pending.map { |item| item.merge("source" => source.name) }
        end
        JSON.generate(mode: "update", count: items.size, items: items)
      rescue => e
        JSON.generate(error: e.message)
      end
    end
  end
end
