# frozen_string_literal: true

module NexoMail
  # What each inbox has already been triaged into — the memory that lets a run read
  # only the mail that arrived since the last one.
  #
  # Before this, every run re-listed the whole window and the model re-classified and
  # re-wrote all of it: a measured run spent 14 minutes on 137 items of which about a
  # dozen were new. The fetch was never the cost; the re-triage was.
  #
  # One JSON file per source under Config.ledger_dir, holding two things:
  #
  #   seen   id => activity stamp, for EVERY message a committed run was shown —
  #          including the ones the agent judged noise and never emitted. This is
  #          what the listing tools filter against.
  #   items  id => the extraction item the agent wrote for it.
  #   pending  the ids of items no committed DIGEST has taken in yet — what lets the
  #          digest be updated with the new mail instead of rebuilt from all of it.
  #
  # Pure bookkeeping, like Snapshots: it holds no opinion about what mail matters,
  # how far back a briefing reaches, or what an item should say. Those stay in the
  # skills; the agent hands the window to #commit.
  #
  # THE CURSOR ONLY MOVES ON COMMIT. A listing tool calls #take, which remembers what
  # it handed out in memory only; #commit is what writes those ids to `seen`. So a run
  # that dies between listing and committing leaves the ledger untouched and the next
  # run is offered the same mail again — nothing is ever marked read that was not
  # triaged. That is also why ledgers are process-wide (see .for): the listing tool
  # and the commit tool are different objects and must share the offered set.
  class Ledger
    VERSION = 1
    INBOX_SUFFIX = ".new.json"

    class << self
      # The one ledger for +key+ in this process.
      def for(key)
        (@open ||= {})[key.to_s] ||= new(key.to_s)
      end

      # A source's ledger, from the extraction file its descriptor names
      # ("hey.json" → the "hey" ledger).
      def for_file(file) = self.for(File.basename(file.to_s, ".json"))

      # Where a source agent writes the items it extracted THIS run, before commit
      # merges them into the full extraction file ("hey.json" → "hey.new.json").
      def inbox_file(file) = File.basename(file.to_s, ".json") + INBOX_SUFFIX

      # Every source's ledger, whether or not that source ran this time.
      def all = Sources.all.map { |source| for_file(source.file) }

      def dir = Config.ledger_dir

      # Forget everything: every source is read in full on the next run.
      def reset!
        @open = {}
        removed = Dir.glob(File.join(dir, "*.json"))
        FileUtils.rm_f(removed)
        removed
      end
    end

    attr_reader :key

    def initialize(key)
      @key = key
      @offered = {}
      @handed = []
      @routed = []
      @committed = false
      load
    end

    # The rows a committed run has not been shown yet, remembered as offered. The
    # block maps a row to its id, or to [id, stamp] when the source has a notion of
    # thread activity: a row whose stamp moved since it was seen is new again.
    def take(rows)
      rows.select do |row|
        id, stamp = yield(row)
        next true if id.nil? # nothing to remember it by: always show it

        fresh?(id, stamp).tap { |fresh| @offered[id.to_s] = stamp.to_s if fresh }
      end
    end

    # Finished items a listing settled without the model (a sender the reader fixed
    # as ephemeral). Held in memory like the offered set and written by #commit, so
    # they too are only on record once the run that listed them committed.
    def route(items) = @routed.concat(Array(items))

    # Is this item already on record? Asked before #commit, to tell a first filing
    # from a thread that came back.
    def known?(item) = @items.key?(item_key(item))

    def fresh?(id, stamp = nil)
      known = @seen[id.to_s]
      known.nil? || (!stamp.nil? && known != stamp.to_s)
    end

    # Some id spaces can be reissued wholesale (IMAP UIDs under a new UIDVALIDITY).
    # When the scope a source reports differs from the one the ids were recorded
    # under, they mean nothing any more: forget what was seen and read afresh. Items
    # stay — they are history, and a re-read at worst repeats one.
    def scope!(value)
      value = value.to_s
      return if value.empty? || @scope == value

      @seen = {} unless @scope.nil?
      @scope = value
    end

    # Merge this run's items, mark everything offered as seen, and persist. Returns
    # the items to brief from: everything kept, newest first, optionally only those
    # received on/after +keep_since+ (an ISO date — the caller's window, not ours).
    def commit(items, keep_since: nil, keep_by_lane: nil)
      (@routed + Array(items)).each do |item|
        next unless item.is_a?(Hash)

        key = item_key(item)
        @items[key] = item
        @pending |= [key]
      end
      @seen.merge!(@offered)
      @offered = {}
      @routed = []
      @committed = true
      save
      export(keep_since, keep_by_lane)
    end

    # True once #commit ran in this process — how the workflow knows a source's
    # extraction file is this run's and not one a previous run left behind.
    def committed? = @committed

    # The same two-step as #take and #commit, one stage later: #take_pending hands
    # the digest builder the items no digest holds yet and remembers them in memory;
    # #digested! is what strikes them off. A digest that is never committed leaves
    # them pending, so the next run hands them over again.
    def take_pending
      @handed = @pending.dup
      @items.values_at(*@handed).compact
    end

    def pending_count = @pending.size

    # +all+ is for a digest rebuilt from the full extraction files, which by
    # construction holds everything on record.
    def digested!(all: false)
      gone = all ? @pending : @handed
      @handed = []
      return if gone.empty?

      @pending -= gone
      save
    end

    def size = @items.size

    def seen_count = @seen.size

    def path = File.join(self.class.dir, "#{key}.json")

    private

    # Each lane may carry its own cutoff (+by_lane+, lane => ISO date); a lane
    # without one, and an item without a lane, falls back to +keep_since+. Both are
    # the caller's dates — how long a lane is worth keeping is the skill's call.
    def export(keep_since, by_lane = nil)
      fallback = keep_since.to_s.strip[0, 10]
      cutoffs = (by_lane || {}).to_h { |lane, date| [lane.to_s, date.to_s.strip[0, 10]] }.reject { |_, date| date.empty? }
      kept = @items.values.select do |item|
        cutoff = cutoffs[item["lane"].to_s] || fallback
        # ISO dates order as strings. An undated item cannot be proven stale: keep it.
        cutoff.empty? || (date = item["received_at"].to_s[0, 10]).empty? || date >= cutoff
      end
      kept.sort_by { |item| item["received_at"].to_s }.reverse
    end

    # The source's own id when the agent carried it over; otherwise a stable key from
    # what identifies the message, so re-committing the same item cannot duplicate it.
    def item_key(item)
      id = item["id"].to_s
      return id unless id.empty?

      "~" + item.values_at("sender_email", "subject", "received_at").join("|")
    end

    def load
      data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      @scope = data["scope"]
      @seen = data["seen"].is_a?(Hash) ? data["seen"] : {}
      @items = data["items"].is_a?(Hash) ? data["items"] : {}
      @pending = data["pending"].is_a?(Array) ? data["pending"] : []
    rescue JSON::ParserError
      # A ledger we cannot read is a ledger we do not have: read everything again
      # rather than refuse to run.
      @scope = nil
      @seen = {}
      @items = {}
      @pending = []
    end

    # Written whole and renamed into place, so an interrupted write cannot leave a
    # half-file behind — that would cost the history, not just one run.
    def save
      FileUtils.mkdir_p(self.class.dir)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.generate("version" => VERSION, "scope" => @scope, "seen" => @seen, "items" => @items, "pending" => @pending))
      File.rename(tmp, path)
    end
  end
end
