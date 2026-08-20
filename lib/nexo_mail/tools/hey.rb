# frozen_string_literal: true

module NexoMail
  module Tools
    # Shared knowledge about HEY's shape: which boxes exist, what the CLI calls them,
    # and how to turn one raw posting into the handful of fields triage actually uses.
    #
    # Two facts here are load-bearing, both learned the hard way:
    #
    # 1. THE CLI NAME IS THE `kind`, NOT THE LABEL. `hey box <name>` wants "feedbox" /
    #    "trailbox" / "asidebox" — the `kind` field from `hey boxes --json`. Passing a
    #    friendly "feed" or "papertrail" is a hard error (exit 2). The model is given
    #    the readable names and BOXES translates; nothing may silently fall back to the
    #    Imbox, which is how The Feed and Paper Trail went untriaged for so long.
    #
    # 2. `posting["id"]` IS NOT THE THREAD ID. `hey threads <id>` wants the TOPIC id,
    #    which appears only inside `app_url` (https://app.hey.com/topics/<TOPIC_ID>) and
    #    is a completely different number. Reading by posting id always 404s. Postings
    #    with kind "bundle" point at /contacts/<id> instead and have no readable thread
    #    at all — #thread_id returns nil for those, and the model is told to skip them.
    #
    # Box ids are per-account, so they are never hardcoded — only these stable `kind`
    # strings are.
    module Hey
      # canonical name (what the model says) => CLI name (what `hey box` wants)
      BOXES = {
        "imbox" => "imbox",
        "feed" => "feedbox",
        "papertrail" => "trailbox",
        "setaside" => "asidebox"
      }.freeze

      LABELS = {
        "imbox" => "Imbox",
        "feed" => "The Feed",
        "papertrail" => "Paper Trail",
        "setaside" => "Set Aside"
      }.freeze

      TOPIC = %r{/topics/(\d+)}

      # `hey` CANNOT be invoked concurrently. It serializes on the macOS keyring, so
      # parallel processes race and every loser exits 3 with "not logged in" —
      # measured over 12 box fetches: 1 in flight -> 12/12 ok, 2 -> 9/12, 3 -> 6/12,
      # 4 -> 3/12. This mutex is the invariant, held for the whole subprocess, so the
      # race is impossible no matter who calls: a Pool fan-out, two tool calls running
      # together under Config.tool_concurrency, or the availability probe in Sources.
      #
      # A plain Mutex is the right primitive even inside the reactor: Ruby's Mutex is
      # fiber-aware, so a contending fiber YIELDS rather than deadlocking the thread
      # (verified: 4 fibers x a 0.2s subprocess serialize in 0.83s, no deadlock), and
      # it still serializes against real threads.
      LOCK = Mutex.new

      module_function

      # Every `hey` invocation in the process goes through here. Returns CliReader's
      # parsed JSON / { error: } shape unchanged.
      def run(*argv)
        LOCK.synchronize { CliReader.json("hey", *argv) }
      end

      def names = BOXES.keys

      def cli_name(canonical) = BOXES[canonical]

      def label(canonical) = LABELS.fetch(canonical, canonical)

      # Normalize whatever the model sent into canonical box names. Deliberately does
      # NOT validate — the caller reports unknown names as an error rather than
      # substituting a box the reader never asked for.
      def normalize(boxes)
        Array(boxes).flatten.map { |b| b.to_s.strip.downcase }.reject(&:empty?).uniq
      end

      # The topic id `hey threads` actually accepts, or nil when the posting has no
      # readable thread (a "bundle" posting points at /contacts/<id>).
      def thread_id(posting)
        posting["app_url"].to_s[TOPIC, 1]&.to_i
      end

      # One posting reduced to the fields triage uses. The raw payload carries nested
      # `contacts`/`addressed_contacts` arrays with avatar URLs and streaming tokens —
      # measured at ~144 KB for 40 Feed postings versus ~16 KB projected. Dropping them
      # is the single largest context saving in the pipeline.
      #
      # `seen` is ABSENT (not false) on unread postings, so `!seen` is the right test.
      def project(posting, snippet_chars:)
        creator = posting["creator"] || {}
        {
          id: posting["id"],
          thread_id: thread_id(posting),
          from: creator["name"] || posting["alternative_sender_name"],
          from_email: creator["email_address"],
          subject: posting["name"],
          date: posting["active_at"] || posting["created_at"],
          unread: !posting["seen"],
          snippet: snippet(posting, snippet_chars),
          messages: posting["visible_entry_count"]
        }.compact
      end

      def snippet(posting, chars)
        return nil unless chars.positive?

        text = posting["summary"].to_s.strip[0, chars]
        text.empty? ? nil : text
      end
    end
  end
end
