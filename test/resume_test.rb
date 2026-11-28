# frozen_string_literal: true

require "test_helper"

# Which run `--resume` picks. It once chose by file time, and sweeping interrupted
# runs rewrites old files, so it picked a stale run.
class ResumeTest < NexoMailTest
  def setup
    super
    @store = Nexo::RunStore::Disk.new(dir: NexoMail::Config.runs_dir)
    Nexo.configure { |c| c.run_store = @store }
    @cli = NexoMail::CLI.new
  end

  def teardown
    Nexo.reset_config!
    super
  end

  def extra_env = %w[NEXO_MAIL_RUNS_KEEP]

  # A run id orders by the millisecond it was created in; real runs are seconds apart.
  def run_with(status)
    sleep 0.002
    @store.create(workflow_class: "NexoMail::Workflows::MultiInboxTriage", payload: {}).tap { |run| run.update!(status: status) }
  end

  def test_the_newest_unfinished_run_is_the_one_started_last
    old = run_with("failed")
    done = run_with("done")
    newest = run_with("interrupted")
    old.update!(error: "rewritten last") # touches the oldest file last

    order = @cli.send(:newest_first).map(&:id)

    assert_equal [newest.id, done.id, old.id], order
    picked = @cli.send(:newest_first).find { |run| NexoMail::CLI::RESUMABLE.include?(run.status) }
    assert_equal newest.id, picked.id
  end

  def test_what_can_be_resumed
    assert_equal %w[suspended failed interrupted], NexoMail::CLI::RESUMABLE
  end

  def test_old_run_documents_are_trimmed_newest_kept
    runs = Array.new(4) { run_with("done") }
    ENV["NEXO_MAIL_RUNS_KEEP"] = "2"

    @cli.send(:trim_runs)

    assert_equal runs.last(2).map(&:id).reverse, @store.all.map(&:id)
  end
end
