# frozen_string_literal: true

require "date"

module NexoMail
  module Tools
    # Lists HEY's boxes as compact JSON via `hey box <name> --limit N --json`. Read-only.
    #
    # ONE call returns every box. Batching here rather than making the model loop is
    # the whole point: one call costs the model one round trip, where a
    # call per box used to mean four — and,
    # because NexoMail::Tools::Hey::BOXES did not agree with what this tool told the
    # model to send, three of those four silently returned the Imbox instead.
    #
    # Ruby bounds VOLUME here, never relevance: the CLI is capped at
    # Config.hey_box_limit postings per box, and Hey.project keeps nine fields,
    # discarding the nested contact objects and avatar URLs that made the raw payload
    # ~9x larger. HOW FAR BACK the briefing reaches is a judgment, so it is the
    # agent's — passed in as `since`. This tool has no idea what today is.
    class HeyBox < RubyLLM::Tool
      description <<~DESC.strip
        List HEY postings as compact JSON (id, thread_id, from, subject, date, unread,
        snippet). Read-only.

        HEY sorts mail into boxes, and each one means something different. Pull them
        ALL in ONE call — that is the intended usage:
          {"boxes": ["imbox", "feed", "papertrail", "setaside"]}
        - "imbox": mail from people that matters -> triage to action/fyi.
        - "feed": newsletters and broadcasts -> usually noise; tag its `topics`
          (e.g. ruby, rails, photography) for the interest radar.
        - "papertrail": receipts, orders, and confirmations -> usually noise; attach
          the `payment` amount and merchant.
        - "setaside": mail the reader deliberately parked -> usually fyi.

        At most 40 postings per box, newest first; `more_waiting` counts untriaged
        postings beyond that, which the next run will list. Pass `since` (an ISO date) to drop
        anything older — you decide how far back the briefing reaches; this tool does
        not know what today is.

        Returns only postings an earlier run has NOT already triaged, plus any whose
        thread has had new activity since; `already_triaged` counts what was left out.
        An empty box means nothing new arrived there.

        A posting may carry `lane`: where this sender's mail has gone before. Treat it
        as the default for that message.

        Every posting carries a `snippet` (~200 characters of the message). Classify
        from it, and read amounts straight out of it when it shows one. Only reach for
        the thread tool for the few messages the snippet genuinely cannot settle.

        IMPORTANT: `thread_id` is NOT the same number as `id`. `thread_id` is what the
        thread tool reads; `id` is only for de-duplication. A posting with no
        `thread_id` has no readable body — classify it from the snippet alone.
      DESC

      LEDGER = "hey"

      parameters do
        array :boxes, description: 'Which boxes to list: any of "imbox", "feed", "papertrail", "setaside". Omit for all four.', required: false do
          string
        end
        integer :limit, description: "Max postings per box (default 40)", required: false
        integer :snippet_chars, description: "Snippet length per posting (default 200)", required: false
        string :since, description: "Drop postings older than this ISO date", required: false
      end

      def execute(boxes: nil, limit: nil, snippet_chars: nil, since: nil)
        names = Hey.normalize(boxes)
        names = Hey.names if names.empty?

        unknown = names - Hey.names
        unless unknown.empty?
          return JSON.generate(
            error: "unknown box(es) #{unknown.inspect} — valid boxes are: #{Hey.names.join(", ")}"
          )
        end

        listed = fetch(names)
        shown = (limit || Config.hey_box_limit).to_i.clamp(1, 200)
        JSON.generate(
          boxes: listed.filter_map { |box, data| box_result(box, data, snippet_chars, cutoff(since), shown) },
          errors: listed.filter_map { |box, data| error_result(box, data) }
        )
      end

      private

      # One `hey` subprocess per box, one after another (see Hey::LOCK). Returns
      # [canonical_name, parsed_payload] pairs; a per-box failure is a payload with an
      # :error key, so one broken box never costs the others.
      #
      # Fetches MORE than it will show (Config.hey_fetch_limit): the cap on what the
      # model sees is applied after the ledger has removed what it already triaged,
      # so mail deeper than one listing is reached on a later run. Capping the fetch
      # itself meant anything past the newest 40 of a box was never triaged at all.
      def fetch(names)
        per_box = Config.hey_fetch_limit.to_s
        names.map { |name| [name, Hey.run("box", Hey.cli_name(name), "--limit", per_box, "--json")] }
      end

      def box_result(box, data, snippet_chars, cutoff, shown)
        postings = data.is_a?(Hash) ? data.dig("data", "postings") : nil
        return nil unless postings.is_a?(Array)

        chars = (snippet_chars || Config.hey_snippet_chars).to_i.clamp(0, 1_000)
        recent = postings.select { |p| cutoff.nil? || recent?(p, cutoff) }
        ledger = Ledger.for(LEDGER)
        # A posting is new again when its thread moved: `active_at` is the stamp.
        stamp = ->(p) { p["active_at"] || p["created_at"] }
        unseen = recent.select { |p| ledger.fresh?(p["id"], stamp.call(p)) }
        # Only what is shown is offered: the rest stays unseen and is listed next run.
        fresh = ledger.take(unseen.sort_by { |p| stamp.call(p).to_s }.last(shown)) { |p| [p["id"], stamp.call(p)] }
        rows = fresh.map { |p| Hey.project(p, snippet_chars: chars) }
          .sort_by { |p| p[:date].to_s }.reverse
        rows, routed = SenderMemory.route(rows) do |row|
          {id: row[:id], sender: row[:from], sender_email: row[:from_email], subject: row[:subject], received_at: row[:date]}
        end
        ledger.route(routed)

        {box: box, label: Hey.label(box), count: rows.size, already_triaged: recent.size - unseen.size,
         more_waiting: unseen.size - fresh.size, routed_ephemeral: routed.size, postings: rows}
      end

      def error_result(box, data)
        return nil unless data.is_a?(Hash)
        return nil if data.dig("data", "postings").is_a?(Array)

        {box: box, error: data[:error] || data["error"] || "unexpected `hey box` payload"}
      end

      # nil when the agent named no cutoff — then nothing is filtered by date.
      def cutoff(since)
        text = since.to_s.strip
        return nil if text.empty?

        Date.parse(text)
      rescue ArgumentError
        nil
      end

      def recent?(posting, cutoff)
        stamp = posting["active_at"] || posting["created_at"]
        return true if stamp.nil? # undated: can't prove it's stale, so keep it

        Date.parse(stamp.to_s) >= cutoff
      rescue ArgumentError
        true # unparseable date: keep rather than silently drop
      end
    end
  end
end
