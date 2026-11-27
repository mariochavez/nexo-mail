# frozen_string_literal: true

module NexoMail
  # Which lane a sender's mail belongs in — so the question is asked of the model
  # once per sender, not once per message.
  #
  # Two sources, and they are not equals:
  #
  #   fixed    the reader's own rules, in Config.senders_file (TOML, address or
  #            domain => lane). Authoritative: the item's lane is stamped from it at
  #            commit whatever the model wrote, and a sender fixed as `ephemeral` is
  #            not shown to the model at all (see #route).
  #   learned  a tally, per address, of the lanes committed items were given. Once a
  #            sender has been seen SETTLE times and always in the same lane, that
  #            lane rides along on its listing rows as a hint. A hint, never a rule:
  #            the model may still say this particular message is something else,
  #            and a sender that has ever been put in two lanes stops being hinted.
  #
  # Like Ledger this is bookkeeping. It has no idea what a lane means or which mail
  # deserves which — it counts what the agent decided and reads what the reader wrote.
  module SenderMemory
    LANES = %w[conversation money dev reading opportunity jobs ephemeral].freeze
    EPHEMERAL = "ephemeral"
    FILE = "senders.json"
    # Times a sender must have been filed, unanimously, before its lane is hinted.
    SETTLE = 2

    class << self
      def path = File.join(Ledger.dir, FILE)

      # The lane the reader fixed for this sender, or nil. An exact address wins over
      # its domain, and a domain over its parent ("news.example.com" → "example.com").
      def fixed(email)
        address = normalize(email)
        return nil if address.nil?

        rules = fixed_rules
        host = address.split("@", 2).last.to_s
        parts = host.split(".")
        candidates = [address] + (0...[parts.size - 1, 1].max).map { |i| parts[i..].join(".") }
        candidates.filter_map { |key| rules[key] }.first
      end

      # The lane to suggest for this sender: the fixed one, else a settled learned
      # one, else nil.
      def hint(email)
        fixed(email) || settled(email)
      end

      # Count the lane each of these items was filed in. Called with the items a
      # commit is adding for the first time, so a thread that comes back is not
      # counted twice.
      def learn(items)
        seen = false
        Array(items).each do |item|
          address = normalize(item["sender_email"])
          lane = item["lane"].to_s
          next if address.nil? || !LANES.include?(lane)

          (learned[address] ||= {})[lane] = learned[address][lane].to_i + 1
          seen = true
        end
        save if seen
      end

      # Split listing rows into those the model should see and those a FIXED
      # `ephemeral` rule already settles. The block maps a row to
      # {id:, sender:, sender_email:, subject:, received_at:}. Kept rows gain a
      # `lane` hint when the sender has one; routed ones come back as finished
      # extraction items — id, sender and subject, nothing the model had to read.
      def route(rows)
        kept = []
        routed = []
        rows.each do |row|
          facts = yield(row)
          lane = hint(facts[:sender_email])
          if lane == EPHEMERAL && fixed(facts[:sender_email]) == EPHEMERAL && !facts[:id].nil?
            routed << ephemeral_item(facts)
          else
            kept << (lane ? row.merge(lane_key(row) => lane) : row)
          end
        end
        [kept, routed]
      end

      # "Name <a@b.c>" or "a@b.c" → "a@b.c"; nil when there is no address in it.
      def normalize(email)
        text = email.to_s[/<([^>]+)>/, 1] || email.to_s
        text = text.strip.downcase
        text.include?("@") ? text : nil
      end

      def reload!
        @learned = nil
        @fixed_rules = nil
      end

      private

      def settled(email)
        tally = learned[normalize(email)]
        return nil unless tally.is_a?(Hash) && tally.size == 1

        lane, count = tally.first
        (count.to_i >= SETTLE) ? lane : nil
      end

      def ephemeral_item(facts)
        {
          "id" => facts[:id].to_s, "lane" => EPHEMERAL, "bucket" => "noise", "category" => "notification",
          "sender" => facts[:sender] || facts[:sender_email], "sender_email" => normalize(facts[:sender_email]),
          "subject" => facts[:subject], "summary" => "", "received_at" => facts[:received_at], "routed" => true
        }.compact
      end

      # Rows keep the key style their tool already uses (symbols for our own tools,
      # strings for an MCP reply).
      def lane_key(row) = row.keys.first.is_a?(Symbol) ? :lane : "lane"

      def learned
        @learned ||= begin
          data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
          data.is_a?(Hash) ? data : {}
        rescue JSON::ParserError
          {}
        end
      end

      def save
        FileUtils.mkdir_p(Ledger.dir)
        tmp = "#{path}.tmp"
        File.write(tmp, JSON.generate(learned))
        File.rename(tmp, path)
      end

      # A rule naming a lane this project does not have is ignored rather than
      # obeyed: it would stamp items with a lane nothing downstream renders.
      def fixed_rules
        @fixed_rules ||= begin
          file = Config.senders_file
          raw = File.exist?(file) ? TomlRB.load_file(file) : {}
          raw.each_with_object({}) do |(key, lane), rules|
            rules[key.to_s.strip.downcase.delete_prefix("@")] = lane if LANES.include?(lane)
          end
        rescue => e
          RubyLLM.logger.warn { "senders file ignored: #{e.class}: #{e.message}" }
          {}
        end
      end
    end
  end
end
