# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "nexo_mail"

# Every test runs against throwaway directories and an empty config, so the suite
# never reads the user's mail, ledger, runs or settings.
class NexoMailTest < Minitest::Test
  DIRS = %w[SANDBOX LEDGER RUNS SNAPSHOTS].freeze

  def setup
    @root = Dir.mktmpdir("nexo-mail-test")
    @env = ENV.to_h.slice(*managed_keys)
    DIRS.each { |name| ENV["NEXO_MAIL_#{name}_DIR"] = File.join(@root, name.downcase).tap { |dir| FileUtils.mkdir_p(dir) } }
    ENV["NEXO_MAIL_CONFIG"] = File.join(@root, "config.toml")
    File.write(ENV["NEXO_MAIL_CONFIG"], config)
    NexoMail::Config.reload!
  end

  def teardown
    managed_keys.each { |key| @env.key?(key) ? ENV[key] = @env[key] : ENV.delete(key) }
    NexoMail::Config.reload!
    FileUtils.rm_rf(@root)
  end

  # The config.toml a test runs with. Empty by default.
  def config = ""

  private

  def managed_keys = ["NEXO_MAIL_CONFIG", *DIRS.map { |name| "NEXO_MAIL_#{name}_DIR" }, *extra_env]

  # More NEXO_MAIL_* variables a test sets, restored afterwards.
  def extra_env = []
end
