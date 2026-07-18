# frozen_string_literal: true

require "date"

module NexoMail
  module Tools
    # Lists one HEY box as JSON via `hey box <name> --limit N --json`. Read-only.
    #
    # HEY sorts mail into three boxes, and each maps to a different triage intent —
    # the description tells the agent so it pulls all three and tags accordingly:
    #   imbox      — people & things that matter → action / fyi
    #   feed       — newsletters & broadcasts    → noise, but tag `topics`
    #   papertrail — receipts & confirmations    → noise, but attach `payment`
    #
    # Two deterministic read-shaping bounds are applied here (never in the agent) so
    # stale mail never reaches triage: the CLI is capped at LIMIT postings per box,
    # and postings whose activity date predates MAX_AGE are dropped before returning.
    class HeyBox < RubyLLM::Tool
      description <<~DESC.strip
        List postings from one HEY box as JSON (sender, subject, id). Read-only.
        Returns at most the 40 most recent postings, and only those from the last
        month — older mail is already discarded, so triage everything you get back.
        Call once per box to see the whole inbox:
        - "imbox": important mail from people — triage to action/fyi.
        - "feed": newsletters and broadcasts — usually noise; tag its topics
          (e.g. ruby, rails, photography) for the interest radar.
        - "papertrail": receipts, orders, and confirmations — usually noise; pull
          the payment amount/merchant from each.
      DESC
      param :box, type: :string, required: false,
        desc: "Which box: imbox (default), feed, or papertrail"

      BOXES = %w[imbox feedbox trailbox].freeze
      LIMIT = 40

      def execute(box: "imbox")
        name = BOXES.include?(box.to_s) ? box.to_s : "imbox"
        data = CliReader.json("hey", "box", name, "--limit", LIMIT.to_s, "--json")
        drop_stale(data)
      end

      private

      # Keep only postings active within the last calendar month. Mutates and returns
      # the parsed payload; passes non-conforming shapes (errors, raw) straight through.
      def drop_stale(data)
        postings = data.is_a?(Hash) ? data.dig("data", "postings") : nil
        return data unless postings.is_a?(Array)

        cutoff = Date.today.prev_month
        data["data"]["postings"] = postings.select { |p| recent?(p, cutoff) }
        data
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
