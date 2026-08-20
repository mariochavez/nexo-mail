# frozen_string_literal: true

module NexoMail
  module Tools
    # Reads HEY message bodies by TOPIC id via `hey threads <id> --json`. Read-only.
    #
    # Takes a LIST of ids and reads them all in one call. `hey threads` itself accepts
    # exactly one id, so the loop lives here — which is the point: the model can only
    # issue tool calls sequentially, so fifteen bodies used to mean fifteen round trips
    # through the model. Now it means one.
    #
    # The ids are TOPIC ids (Hey.thread_id, parsed out of a posting's app_url), NOT
    # posting ids. Reading by posting id always 404s — see NexoMail::Tools::Hey.
    #
    # Bounded on three axes, because HEY bodies are otherwise unlimited and this is the
    # one tool that can flood a context: at most Config.hey_thread_max_ids threads,
    # Config.hey_body_chars per entry, and Config.hey_payload_max_chars for the whole
    # reply.
    class HeyThread < RubyLLM::Tool
      description <<~DESC.strip
        Read HEY message BODIES by thread id — pass ALL the ids you need in ONE call
        (up to 15). Read-only. Example: {"thread_ids": [2103920594, 2104108150]}

        The ids come from the `thread_id` field of the box listing. Do NOT pass a
        posting `id`: that is a different number and will not resolve. A posting with
        no `thread_id` has no readable body — skip it.

        Only call this for messages the listing snippet could not settle: a receipt
        whose exact total you must read, an invitation whose time you need, a genuinely
        ambiguous sender. Collect those ids first, then make one call.
      DESC

      params do
        array :thread_ids, description: "thread_id values from the box listing" do
          integer
        end
        integer :max_chars, description: "Max body characters per thread entry (default 4000)", required: false
      end

      def execute(thread_ids:, max_chars: nil)
        ids = Array(thread_ids).flatten.map { |id| id.to_i }.reject(&:zero?).uniq
        return JSON.generate(threads: [], error: "no usable thread_ids — pass the listing's `thread_id`, not its `id`") if ids.empty?

        cap = Config.hey_thread_max_ids
        skipped = ids.drop(cap)
        ids = ids.first(cap)

        chars = (max_chars || Config.hey_body_chars).to_i.clamp(200, 20_000)
        payloads = Pool.map(ids, size: Config.hey_concurrency) do |id|
          Hey.run("threads", id.to_s, "--json")
        end

        threads, truncated = bound(ids.zip(payloads).map { |id, data| thread(id, data, chars) })
        JSON.generate({threads: threads, skipped: skipped, truncated: truncated}.reject { |_, v| v == [] || v == false })
      end

      private

      def thread(id, data, chars)
        entries = data.is_a?(Hash) ? data["data"] : nil
        return {thread_id: id, error: error_for(data)} unless entries.is_a?(Array)

        {thread_id: id, entries: entries.map { |e| entry(e, chars) }}
      end

      def entry(raw, chars)
        creator = raw["creator"] || {}
        body = squeeze(raw["body"])
        {
          from: presence(creator["name"]) || presence(raw["alternative_sender_name"]),
          from_email: presence(creator["email_address"]),
          date: presence(raw["created_at"]),
          body: body[0, chars],
          truncated: (body.length > chars) || nil
        }.compact
      end

      # `hey` reports its own failures as an { "ok" => false, "error" => ... } envelope
      # on stdout; CliReader wraps process-level failures as { error: }. Surface either.
      def error_for(data)
        return "unexpected `hey threads` payload" unless data.is_a?(Hash)

        data[:error] || data["error"] || "unexpected `hey threads` payload"
      end

      # Last line of defence on total size: keep whole threads until the budget is
      # spent, then report the rest as dropped rather than silently overflowing.
      def bound(threads)
        budget = Config.hey_payload_max_chars
        kept = []
        threads.each do |t|
          size = JSON.generate(t).length
          break if !kept.empty? && (budget -= size).negative?

          kept << t
        end
        [kept, kept.size < threads.size]
      end

      # HEY hands back already-decoded UTF-8 plain text, so unlike Gmail there is no
      # MIME layer to unwrap — only the padding to collapse, so the character budget
      # buys content instead of indentation.
      def squeeze(text)
        text.to_s.gsub(/\r\n?/, "\n").gsub(/[ \t]+/, " ").gsub(/ ?\n ?/, "\n").gsub(/\n{3,}/, "\n\n").strip
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
