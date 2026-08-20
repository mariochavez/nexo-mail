# frozen_string_literal: true

require "date"

module NexoMail
  module Tools
    # A clock. Reports today's date and the calendar around it — nothing else.
    #
    # This is the one fact a model genuinely cannot obtain: it has no notion of the
    # current date, and it showed. A run generated on 2026-08-20 published a schedule
    # of 2026-06-18 / 2026-07-17 / 2026-07-23 — every appointment already past — and
    # reported 2023 receipts as current charges.
    #
    # Deliberately NOT a date policy engine. It does not decide what "recent" means,
    # what belongs in the briefing, or which appointments are worth showing — those
    # are judgments, and they live in the skills. Give the agent the calendar and let
    # it reason; comparing ISO dates is something a model does reliably once it knows
    # what day it is.
    #
    # Dates are LOCAL, not UTC: "today" means the reader's day.
    class Today < RubyLLM::Tool
      description <<~DESC.strip
        Today's date and the calendar around it. Read-only.

        You do NOT know what day it is on your own, and you must never infer it from
        the contents of an email. Call this FIRST, before you decide what counts as
        recent, current, or still upcoming, and use what it returns for every date
        comparison you make.

        Returns `today`, `weekday`, the current `month` with its `month_start` and
        `month_end`, and `previous_month` / `next_month`.
      DESC

      def execute
        today = Date.today
        first = Date.new(today.year, today.month, 1)

        JSON.generate(
          today: today.iso8601,
          now: Time.now.iso8601,
          weekday: today.strftime("%A"),
          month: today.strftime("%Y-%m"),
          month_name: today.strftime("%B %Y"),
          month_start: first.iso8601,
          month_end: Date.new(today.year, today.month, -1).iso8601,
          previous_month: first.prev_month.strftime("%Y-%m"),
          previous_month_start: first.prev_month.iso8601,
          next_month: first.next_month.strftime("%Y-%m")
        )
      end
    end
  end
end
