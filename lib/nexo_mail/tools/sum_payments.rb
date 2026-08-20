# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module NexoMail
  module Tools
    # A calculator. Adds up the payments it is handed, per currency, and hands back
    # each currency's list together with that currency's totals.
    #
    # It makes NO judgments. It does not decide which payments belong in the
    # briefing, what counts as recent, or what an ambiguous direction probably meant
    # — those are the skills' calls. It only does the arithmetic, which is the part
    # that was measurably wrong: a real run reported USD `charged: 289.00` while its
    # own list summed to 269.00, and MXN `refund: 7,979.84` against a list summing to
    # 7,899.98 with `count: 5` for four entries.
    #
    # The SHAPE is the fix as much as the addition. Every currency is a self-contained
    # block holding its own `charges` list AND its totals, computed from exactly that
    # list. Copy a currency's block into the digest and its totals cannot disagree
    # with its list, because there is no second place for either to come from.
    #
    # Three deliberate refusals:
    #   - NEVER converts between currencies. There is no exchange rate here, and two
    #     honest totals beat one invented one.
    #   - NEVER guesses a direction. A payment whose direction isn't one of the four
    #     comes back under `needs_direction`, uncounted and visible, rather than being
    #     quietly filed as a charge.
    #   - NEVER invents or drops an amount. Anything unusable comes back in `ignored`.
    class SumPayments < RubyLLM::Tool
      description <<~DESC.strip
        Add up payments, separated by currency. Deterministic — use this instead of
        doing the arithmetic yourself, and copy its answer into the digest rather
        than re-deriving it.

        Pass EVERY payment you want counted, in ONE call. You decide which ones
        belong (this tool has no idea what today is or what the briefing covers); it
        only adds up what you give it.

        You get back `by_currency`, where each currency holds its OWN `charges` list
        and its OWN totals computed from that list — write both from the same block
        so they cannot disagree. Amounts are summed exactly, with no floating-point
        drift, and currencies are NEVER converted into one another.

        Payments with an unrecognised `direction` come back under `needs_direction`
        and are NOT counted; ones with no usable amount come back under `ignored`.
        Neither is silently dropped — fix them and call again, or report them as-is.
      DESC

      params do
        array :payments, description: "The payments to add up" do
          object do
            number :amount, description: "The number only, e.g. 1234.50"
            string :currency, description: "ISO code, e.g. USD, MXN", required: false
            string :direction, description: "paid | charged | due | refund", required: false
            string :merchant, description: "Who was paid or who billed", required: false
            string :kind, description: "one_time | subscription", required: false
            string :date, description: "ISO date of the payment", required: false
            string :subject, description: "The message subject", required: false
            string :source, description: "Which inbox it came from", required: false
          end
        end
      end

      # Money OUT is paid + charged + due; refund is money coming back.
      OUTFLOW = %w[paid charged due].freeze
      DIRECTIONS = (OUTFLOW + %w[refund]).freeze
      UNKNOWN_CURRENCY = "UNKNOWN"

      def execute(payments:)
        rows = Array(payments).map { |p| normalize(p) }
        usable, ignored = rows.partition { |r| r[:amount] }
        counted, undirected = usable.partition { |r| DIRECTIONS.include?(r[:direction]) }

        JSON.generate(
          {
            currencies: counted.map { |r| r[:currency] }.uniq.sort,
            by_currency: by_currency(counted),
            needs_direction: undirected.map { |r| present(r).merge(reason: "direction must be one of: #{DIRECTIONS.join(", ")}") },
            ignored: ignored.map { |r| present(r).merge(reason: "no usable amount") }
          }.reject { |_, v| v == [] }
        )
      end

      private

      # Each currency is self-contained: its list, and the totals OF that list.
      def by_currency(rows)
        rows.group_by { |r| r[:currency] }.sort.to_h do |currency, group|
          sums = DIRECTIONS.to_h { |d| [d, total(group.select { |r| r[:direction] == d })] }
          out = OUTFLOW.sum(BigDecimal(0)) { |d| sums[d] }
          [currency, sums.transform_values { |v| money(v) }.merge(
            "out" => money(out),
            "net" => money(out - sums["refund"]),
            "count" => group.size,
            "subscriptions" => group.count { |r| r[:kind] == "subscription" },
            "charges" => group.map { |r| present(r) }
          )]
        end
      end

      def total(rows) = rows.sum(BigDecimal(0)) { |r| r[:amount] }

      # BigDecimal via the STRING form: BigDecimal(0.1, n) inherits the float's error,
      # BigDecimal("0.1") does not. Money must never be summed as Float.
      def normalize(payment)
        raw = payment.is_a?(Hash) ? payment.transform_keys(&:to_sym) : {}
        {
          merchant: presence(raw[:merchant]),
          amount: decimal(raw[:amount]),
          currency: currency(raw[:currency]),
          direction: raw[:direction].to_s.strip.downcase,
          kind: (raw[:kind].to_s.strip.downcase == "subscription") ? "subscription" : "one_time",
          date: presence(raw[:date]),
          subject: presence(raw[:subject]),
          source: presence(raw[:source])
        }
      end

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
