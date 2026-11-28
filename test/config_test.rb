# frozen_string_literal: true

require "test_helper"

class ConfigTest < NexoMailTest
  def config
    <<~TOML
      [read]
      cli_timeout = 45
      apple_body_chars = 999999

      [dashboard]
      sandbox = "local"
    TOML
  end

  def extra_env = %w[NEXO_MAIL_CLI_TIMEOUT NEXO_MAIL_DASHBOARD_RUBY]

  def test_a_setting_is_read_and_clamped_to_its_range
    assert_equal 45, NexoMail::Config.cli_timeout
    assert_equal 20_000, NexoMail::Config.apple_body_chars, "clamped to the top of its range"
  end

  def test_the_environment_wins_over_the_file
    ENV["NEXO_MAIL_CLI_TIMEOUT"] = "7"

    assert_equal 7, NexoMail::Config.cli_timeout
  end

  def test_the_dashboard_uses_the_running_ruby_unless_one_is_pinned
    assert_equal RbConfig.ruby, NexoMail::Config.dashboard_ruby
    assert_includes NexoMail::Config.dashboard_readable, :ruby

    ENV["NEXO_MAIL_DASHBOARD_RUBY"] = RbConfig.ruby
    assert_equal RbConfig.ruby, NexoMail::Config.dashboard_ruby
    refute_includes NexoMail::Config.dashboard_readable, :ruby, "a pinned Ruby grants its own install prefix"
  end

  def test_an_unknown_dashboard_sandbox_is_refused
    File.write(ENV["NEXO_MAIL_CONFIG"], "[dashboard]\nsandbox = \"cloud\"\n")
    NexoMail::Config.reload!

    assert_raises(NexoMail::Error) { NexoMail::Config.dashboard_sandbox }
  end
end
