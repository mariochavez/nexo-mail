# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module NexoMail
  module Tools
    # The money picture for a period, computed from the payments on record.
    #
    # It replaces Tools::SumPayments, which added up whatever payments the model
    # re-typed into its arguments. That was correct arithmetic over an unreliable
    # transcription, and slow: one pending payment once sent the digest builder back
    # through every extraction file to re-send all the charges. Here the rows come
    # straight from the ledgers — every extraction item carrying a `payment` — and
    # the finished `finance` section is staged for CommitDigest, so the model
    # neither sends the numbers in nor copies them out.
    #
    # It makes NO judgments. The period is the caller's (this still has no idea what
    # today is); which bill a payment settled and which row merely repeats another
    # are the caller's too, passed in as `settled` and `skip` and remembered. What
    # it does on its own is only what is exact:
    #   - sums per currency with BigDecimal, NEVER converting between currencies;
    #   - counts a row identical to another (merchant, amount, currency, direction,
    #     date) once;
    #   - refuses to guess a direction — unrecognised ones come back uncounted.
    #
    # History: the totals and the list once drifted when produced separately (USD
    # `charged: 289.00` against a list summing to 269.00), which is why each currency
    # block carries its own rows AND the totals of exactly those rows.
    class MoneyReport < RubyLLM::Tool
      description <<~DESC.strip
        The money picture for a period, from every payment on record. Deterministic:
        you do not pass payments in and you do not copy the result out — the
        `finance` section it builds is saved by commit_digest automatically, so leave
        `finance` out of digest.update.json.

        Pass `since` and `until` (ISO dates — you decide the period; this tool does
        not know what today is). Optionally `compare_since`/`compare_until` for an
        earlier period's totals, and `bills_since` to list unpaid bills that arrived
        before `since`.

        Returns, per currency and never converted: `income`, `refund`, `paid`,
        `charged`, `due`, plus `out` (paid + charged + due), `in` (income + refund)
        and that currency's rows. Also `open_bills` (unpaid, with `overdue`),
        `previous` totals, and `recurring_missing` — merchants billed in two or more
        earlier months with nothing in this period.

        Two calls are yours to make when the rows show them:
        - a bill and the later payment of that same bill: pass
          `settled: [{"bill": "<bill row id>", "payment": "<payment row id>"}]` so
          the bill stops counting as due;
        - a row that is the same transaction as another under different wording:
          pass its id in `skip`.
        Both are remembered for later runs. Rows with an unrecognised `direction`
        come back under `needs_direction`, uncounted.
      DESC

      parameters do
        string :since, description: "ISO date the period starts"
        string :until, description: "ISO date the period ends (today)"
        string :compare_since, description: "ISO date an earlier period starts", required: false
        string :compare_until, description: "ISO date that earlier period ends", required: false
        string :bills_since, description: "Also list unpaid bills dated on/after this ISO date", required: false
        array :settled, description: "Bills that a later payment settled", required: false do
          object do
            string :bill, description: "The bill's row id"
            string :payment, description: "The row id of the payment that settled it"
          end
        end
        array :skip, description: "Row ids that repeat another row's transaction", required: false do
          string
        end
      end

      # Money OUT is paid + charged + due; money IN is income + refund.
      OUTFLOW = %w[paid charged due].freeze
      INFLOW = %w[income refund].freeze
      DIRECTIONS = (OUTFLOW + INFLOW).freeze
      KINDS = %w[one_time subscription bill statement].freeze
      UNKNOWN_CURRENCY = "UNKNOWN"
      STATE = "money.json"
      CHART_BARS = 5

      def execute(since:, until:, compare_since: nil, compare_until: nil, bills_since: nil, settled: nil, skip: nil)
        from = day(since)
        to = day(binding.local_variable_get(:until))
        return JSON.generate(error: "`since` and `until` must be ISO dates") if from.empty? || to.empty?

        remember(settled, skip)
        rows, repeats = distinct(all_rows.reject { |r| skipped.include?(r[:id]) })
        paid_bills = marks["settled"]
        counted = rows.reject { |r| paid_bills.key?(r[:id]) }
        usable = counted.select { |r| r[:amount] && DIRECTIONS.include?(r[:direction]) }
        period = usable.select { |r| r[:date]&.between?(from, to) }

        finance = {
          period: {since: from, until: to},
          currencies: period.map { |r| r[:currency] }.uniq.sort,
          by_currency: by_currency(period),
          open_bills: open_bills(counted, day(bills_since).then { |d| d.empty? ? from : d }, to),
          previous: previous(usable, day(compare_since), day(compare_until)),
          recurring_missing: recurring_missing(usable, period, from)
        }
        finance.merge!(chart(finance[:by_currency]))
        finance = finance.reject { |_, v| v.nil? || v == [] || v == {} }
        DigestFile.stage("finance", JSON.parse(JSON.generate(finance)))

        JSON.generate(finance.merge(
          needs_direction: counted.select { |r| r[:amount] && !DIRECTIONS.include?(r[:direction]) }.map { |r| present(r) },
          repeats_counted_once: repeats,
          note: "Saved as `finance` by commit_digest — do not write it yourself."
        ).reject { |_, v| v == [] })
      rescue => e
        JSON.generate(error: e.message)
      end

      private

      # ---- rows ---------------------------------------------------------------

      # Every payment on record, one row per extraction item, labelled with the
      # inbox it came from. The id is "<ledger>:<item id>" so two inboxes cannot
      # collide and the model can hand it back in `settled`/`skip`.
      def all_rows
        Sources.all.flat_map do |source|
          ledger = Ledger.for_file(source.file)
          ledger.items.filter_map { |item| row(item, ledger.key, source.name) }
        end
      end

      def row(item, key, source)
        payment = item["payment"]
        return nil unless payment.is_a?(Hash)

        kind = payment["kind"].to_s.strip.downcase
        {
          id: "#{key}:#{item["id"]}",
          merchant: presence(payment["merchant"]) || presence(item["sender"]),
          amount: decimal(payment["amount"]),
          currency: currency(payment["currency"]),
          direction: payment["direction"].to_s.strip.downcase,
          kind: KINDS.include?(kind) ? kind : "one_time",
          date: presence(day(payment["date"])) || presence(day(item["received_at"])),
          due_date: presence(day(payment["due_date"])),
          subject: presence(item["subject"]),
          source: source
        }
      end

      # A row identical to an earlier one in every field that makes a transaction is
      # the same transaction seen twice (two inboxes, or a receipt and its copy).
      # Anything looser than identical is a judgment and arrives through `skip`.
      def distinct(rows)
        seen = {}
        kept = rows.select do |r|
          next true unless r[:amount]

          key = [r[:merchant].to_s.downcase, r[:amount], r[:currency], r[:direction], r[:date]]
          seen.key?(key) ? false : (seen[key] = true)
        end
        [kept, rows.size - kept.size]
      end

      # ---- sections -----------------------------------------------------------

      # Each currency is self-contained: its rows, and the totals OF those rows.
      def by_currency(rows)
        rows.group_by { |r| r[:currency] }.sort.to_h do |code, group|
          sums = totals(group)
          [code, sums.merge(
            "count" => group.size,
            "subscriptions" => group.count { |r| r[:kind] == "subscription" },
            "charges" => group.sort_by { |r| r[:date].to_s }.reverse.map { |r| present(r) }
          )]
        end
      end

      def totals(group)
        sums = DIRECTIONS.to_h { |d| [d, group.select { |r| r[:direction] == d }.sum(BigDecimal(0)) { |r| r[:amount] }] }
        out = OUTFLOW.sum(BigDecimal(0)) { |d| sums[d] }
        inflow = INFLOW.sum(BigDecimal(0)) { |d| sums[d] }
        sums.transform_values { |v| money(v) }.merge("out" => money(out), "in" => money(inflow), "net" => money(inflow - out))
      end

      # Unpaid bills, amount or no amount — a bill whose notice shows no figure is
      # still a bill. `overdue` is plain date order against the caller's `until`.
      def open_bills(rows, from, to)
        rows.select { |r| r[:direction] == "due" && r[:date] && r[:date] >= from && r[:date] <= to }
          .sort_by { |r| [r[:due_date] || "9999", r[:date]] }
          .map { |r| present(r).merge(overdue: !r[:due_date].nil? && r[:due_date] < to) }
      end

      def previous(rows, from, to)
        return nil if from.empty? || to.empty?

        rows.select { |r| r[:date]&.between?(from, to) }
          .group_by { |r| r[:currency] }.sort.to_h { |code, group| [code, totals(group).slice("out", "in", "net")] }
          .then { |blocks| blocks.empty? ? nil : {since: from, until: to, by_currency: blocks} }
      end

      # Merchants with outflow in two or more distinct calendar months before the
      # period and none inside it. Set arithmetic only: whether one is actually LATE
      # (or simply not due yet this month) is for the skill to say.
      def recurring_missing(rows, period, from)
        present_now = period.map { |r| [r[:merchant].to_s.downcase, r[:currency]] }.uniq
        rows.select { |r| OUTFLOW.include?(r[:direction]) && r[:date] && r[:date] < from && r[:merchant] }
          .group_by { |r| [r[:merchant].downcase, r[:currency]] }
          .except(*present_now)
          .filter_map do |_, group|
            months = group.map { |r| r[:date][0, 7] }.uniq
            next if months.size < 2

            last = group.max_by { |r| r[:date] }
            {merchant: last[:merchant], currency: last[:currency], months_seen: months.size,
             last_date: last[:date], last_amount: money(last[:amount])}
          end
      end

      # The currency with the largest outflow, and its biggest payees. Picked by
      # size, never by summing across currencies.
      def chart(blocks)
        code, block = blocks.max_by { |_, b| b["out"] }
        return {} unless block && block["out"].positive?

        bars = block["charges"].select { |c| OUTFLOW.include?(c[:direction]) }
          .group_by { |c| c[:merchant] || "—" }
          .map { |merchant, group| {label: merchant, amount: money(group.sum(BigDecimal(0)) { |c| c[:amount].to_d })} }
          .sort_by { |bar| -bar[:amount] }.first(CHART_BARS)
        {dominant_currency: code, chart: {currency: code, bars: bars}}
      end

      # ---- what the caller told us, kept --------------------------------------

      def remember(settled, skip)
        pairs = Array(settled).filter_map do |pair|
          pair = pair.to_h.transform_keys(&:to_s)
          [pair["bill"].to_s, pair["payment"].to_s] unless pair["bill"].to_s.empty?
        end
        ids = Array(skip).map(&:to_s).reject(&:empty?)
        return if pairs.empty? && ids.empty?

        marks["settled"].merge!(pairs.to_h)
        marks["skipped"] |= ids
        FileUtils.mkdir_p(Ledger.dir)
        File.write(state_path, JSON.generate(marks))
      end

      def skipped = marks["skipped"]

      def marks
        @marks ||= begin
          data = File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
          {"settled" => data["settled"].is_a?(Hash) ? data["settled"] : {},
           "skipped" => data["skipped"].is_a?(Array) ? data["skipped"] : []}
        rescue JSON::ParserError
          {"settled" => {}, "skipped" => []}
        end
      end

      def state_path = File.join(Ledger.dir, STATE)

      # ---- values -------------------------------------------------------------

      # BigDecimal via the STRING form: BigDecimal(0.1, n) inherits the float's
      # error, BigDecimal("0.1") does not. Money must never be summed as Float.
      def decimal(value)
        text = value.to_s.strip
        return nil if text.empty?

        d = BigDecimal(text)
        d.zero? ? nil : d.abs # a refund is a positive amount plus direction: refund
      rescue ArgumentError, TypeError
        nil
      end

      def currency(value)
        code = value.to_s.strip.upcase
        code.match?(/\A[A-Z]{3}\z/) ? code : UNKNOWN_CURRENCY
      end

      def money(decimal) = decimal.round(2).to_f

      def day(value) = value.to_s.strip[0, 10].to_s.then { |text| text.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? text : "" }

      def present(row)
        row.merge(amount: row[:amount] && money(row[:amount])).reject { |_, v| v.nil? || v == "" }
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
