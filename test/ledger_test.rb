# frozen_string_literal: true

require "test_helper"

# The ledger is what keeps a run from reading mail an earlier run triaged.
class LedgerTest < NexoMailTest
  ROWS = [{"id" => 1, "at" => "t1"}, {"id" => 2, "at" => "t1"}].freeze

  def take(ledger, rows = ROWS) = ledger.take(rows) { |row| [row["id"], row["at"]] }

  def test_rows_are_offered_until_a_run_commits
    first = NexoMail::Ledger.new("box")

    assert_equal ROWS, take(first)
    refute first.committed?
    assert_equal ROWS, take(NexoMail::Ledger.new("box")), "an uncommitted run leaves nothing on record"
  end

  def test_a_committed_run_is_not_offered_the_same_mail_again
    ledger = NexoMail::Ledger.new("box")
    take(ledger)
    ledger.commit([{"id" => 1, "subject" => "Hello"}])

    assert ledger.committed?
    assert_empty take(NexoMail::Ledger.new("box")), "read back from disk"
  end

  def test_a_thread_that_moved_is_new_again
    ledger = NexoMail::Ledger.new("box")
    take(ledger)
    ledger.commit([])

    moved = [{"id" => 1, "at" => "t2"}, {"id" => 2, "at" => "t1"}]

    assert_equal [moved.first], take(NexoMail::Ledger.new("box"), moved)
  end

  def test_a_row_with_no_id_is_always_shown
    ledger = NexoMail::Ledger.new("box")

    assert_equal [{"at" => "t1"}], ledger.take([{"at" => "t1"}]) { |row| [row["id"], row["at"]] }
  end
end
