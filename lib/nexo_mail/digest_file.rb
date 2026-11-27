# frozen_string_literal: true

require "date"

module NexoMail
  # `digest.json` as something that is kept and amended, not rebuilt.
  #
  # The ledger made reading an inbox cost seconds, which left the digest as the
  # whole cost of a run: the builder re-read every item on record and re-wrote all
  # of digest.json to take in a handful of new messages (measured: 9m09s and every
  # one of its 20 rounds on a 212-item seed). This is the bookkeeping that lets it
  # do less:
  #
  #   .plan     which of three runs this is — decided from what is on record, never
  #             from what the digest says:
  #               :full     no digest was ever committed (or too much is waiting to
  #                         amend sensibly): build it from the extraction files.
  #               :update   a digest exists: hand the builder only the items no
  #                         digest holds yet and let it change what they touch.
  #               :current  nothing is waiting and the digest was built today:
  #                         there is nothing to do.
  #   .commit   takes the top-level keys the builder wrote and replaces exactly
  #             those in digest.json — or, under `edit`, puts and drops single
  #             entries of a list by the field that identifies them — then strikes
  #             the items it was handed off the ledgers' pending lists.
  #
  # Like Ledger it holds no opinion about the content: it adds nothing up, orders
  # nothing and decides nothing. It replaces what it is told to replace and reports
  # how long the lists ended up.
  #
  # THE PENDING LIST ONLY SHRINKS ON COMMIT — the ledger's rule, one stage later.
  # A builder that fails, or never calls commit, leaves every item pending and the
  # next run hands them over again.
  module DigestFile
    FILE = "digest.json"
    UPDATE = "digest.update.json"
    STATE = "digest.state"
    # What a digest cannot be a digest without — the check that a full build did
    # not hand over a fragment.
    CORE = %w[generated_at counts action fyi].freeze
    # The lists whose entries can be put or dropped one at a time, and the field
    # that says which entry is which. Without this a single new card meant
    # re-emitting its whole list: a measured update wrote 13KB to place five items.
    EDITABLE = {"action" => "id", "fyi" => "id", "stories" => "title", "people" => "name",
                "topics" => "topic", "dev" => "ref", "opportunities" => "id", "jobs" => "id"}.freeze
    EDIT = "edit"

    class << self
      def path = File.join(Config.sandbox_dir, FILE)

      def update_path = File.join(Config.sandbox_dir, UPDATE)

      # Kept beside the ledgers, not in the workspace: it is a fact about what was
      # committed, and the workspace is the agents' to write.
      def state_path = File.join(Ledger.dir, STATE)

      def built? = File.exist?(state_path) && File.exist?(path)

      # The local day the digest was last committed — the reader's day, as in
      # Tools::Today.
      def built_on = state["built_on"]

      def pending = Ledger.all.sum(&:pending_count)

      def plan = @plan ||= plan!

      # Decide afresh. The workflow calls this once the inboxes are read, because
      # their commits are what fill the pending lists.
      def plan!
        @committed = false
        @plan = decide
      end

      # True once #commit ran in this process — how the workflow knows the digest
      # in the workspace is this run's. The file's existence proves nothing: it
      # survives from the run before.
      def committed? = @committed == true

      # Replace the top-level keys in +update+ (a Hash), or the whole digest on a
      # full build. Returns what was done; raises ArgumentError with a message meant
      # for the builder when the update cannot be applied.
      def commit(update)
        raise ArgumentError, "the update must be a JSON object of top-level digest keys" unless update.is_a?(Hash)

        update = update.dup
        edits = update.delete(EDIT)
        whole = plan == :full && !committed?
        digest = whole ? whole_digest(update) : current.merge(update)
        edited = apply(edits, digest)
        write(digest)
        Ledger.all.each { |ledger| ledger.digested!(all: whole) }
        save_state
        @committed = true
        {mode: whole ? "full" : "update", replaced: update.keys, edited: edited, lists: lists(digest)}
      end

      # The charges the saved digest already lists, every currency together — each
      # one a row Tools::SumPayments itself produced. Empty when there is no digest.
      def saved_charges
        blocks = current.dig("finance", "by_currency")
        return [] unless blocks.is_a?(Hash)

        blocks.values.grep(Hash).flat_map { |block| Array(block["charges"]) }
      rescue ArgumentError
        []
      end

      # Forget that a digest was ever built: the next run rebuilds it in full from
      # the items on record, without re-reading any mail.
      def forget!
        @plan = nil
        FileUtils.rm_f(state_path)
      end

      # Remove a half-written update from the workspace before the builder runs, so
      # it writes a fresh file instead of paying a round trip to read this one first.
      def clear = FileUtils.rm_f(update_path)

      private

      def decide
        return :full unless built?

        waiting = pending
        return :full if waiting > Config.digest_rebuild_over
        return :current if waiting.zero? && built_on == Date.today.iso8601

        :update
      end

      def whole_digest(update)
        missing = CORE - update.keys
        return update if missing.empty?

        raise ArgumentError, "this is a full build, so the file must hold the whole digest — missing: #{missing.join(", ")}"
      end

      def current
        data = JSON.parse(File.read(path, encoding: "UTF-8"))
        return data if data.is_a?(Hash)

        raise ArgumentError, "#{FILE} is not a JSON object — write the whole digest instead"
      rescue JSON::ParserError, Errno::ENOENT
        raise ArgumentError, "#{FILE} could not be read — write the whole digest instead"
      end

      # `{"action": {"put": [entry, …], "drop": ["<id>", …]}}`, applied in place. A
      # put entry replaces the one carrying the same identity where it stands, and
      # otherwise goes first — new mail leads. Checked whole before anything is
      # changed, so a bad edit applies none of itself.
      def apply(edits, digest)
        return [] if edits.nil?
        raise ArgumentError, "`#{EDIT}` must be an object of list name => {put, drop}" unless edits.is_a?(Hash)

        edits.each do |list, change|
          field = EDITABLE[list] or raise ArgumentError, "`#{list}` cannot be edited entry by entry (only #{EDITABLE.keys.join(", ")}) — replace the key whole instead"
          raise ArgumentError, "`#{EDIT}.#{list}` must be an object with `put` and/or `drop`" unless change.is_a?(Hash)
          unless Array(change["put"]).all? { |entry| entry.is_a?(Hash) && !entry[field].to_s.empty? }
            raise ArgumentError, "every entry put into `#{list}` needs its `#{field}`"
          end
        end

        edits.each do |list, change|
          field = EDITABLE[list]
          entries = Array(digest[list])
          dropped = Array(change["drop"]).map(&:to_s)
          entries = entries.reject { |entry| entry.is_a?(Hash) && dropped.include?(entry[field].to_s) }
          Array(change["put"]).reverse_each do |entry|
            at = entries.index { |existing| existing.is_a?(Hash) && existing[field].to_s == entry[field].to_s }
            at ? entries[at] = entry : entries.unshift(entry)
          end
          digest[list] = entries
        end
        edits.keys
      end

      # One top-level key per line: compact enough to read back cheaply on the next
      # update, and still one section per line when a human diffs two digests.
      def write(digest)
        body = digest.map { |key, value| "#{JSON.generate(key)}: #{JSON.generate(value)}" }.join(",\n")
        tmp = "#{path}.tmp"
        File.write(tmp, "{\n#{body}\n}\n")
        File.rename(tmp, path)
      end

      # The lengths of the lists as written, beside the counts the builder stated,
      # so it can see a mismatch without re-reading its own file. Reported, never
      # corrected: what belongs in a list is the builder's call.
      def lists(digest)
        EDITABLE.keys.to_h { |list| [list, Array(digest[list]).size] }.merge("counts" => digest["counts"])
      end

      def state
        File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
      rescue JSON::ParserError
        {}
      end

      def save_state
        FileUtils.mkdir_p(Ledger.dir)
        File.write(state_path, JSON.generate("built_on" => Date.today.iso8601, "at" => Time.now.iso8601))
      end
    end
  end
end
