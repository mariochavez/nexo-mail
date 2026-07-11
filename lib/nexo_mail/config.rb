# frozen_string_literal: true

module NexoMail
  # Loads and exposes the XDG TOML config. Precedence for every setting is
  # ENV (NEXO_MAIL_*) > config.toml value > built-in default, and any string value
  # in the TOML may reference an env var via ${VAR} or ${VAR:-fallback}.
  module Config
    APP = "nexo-mail"

    Model = Struct.new(:alias, :provider, :model, :api_base, :api_key, keyword_init: true)

    module_function

    # --- XDG locations --------------------------------------------------------
    def config_home = File.expand_path(env("XDG_CONFIG_HOME") || "~/.config")
    def state_home  = File.expand_path(env("XDG_STATE_HOME") || "~/.local/state")
    def config_dir  = File.join(config_home, APP)

    def config_file
      override = env("NEXO_MAIL_CONFIG")
      override ? File.expand_path(override) : File.join(config_dir, "config.toml")
    end

    def skills_dir  = path("NEXO_MAIL_SKILLS_DIR", data["skills_dir"], File.join(config_dir, "skills"))
    def prompts_dir = path("NEXO_MAIL_PROMPTS_DIR", data["prompts_dir"], File.join(config_dir, "prompts"))
    def sandbox_dir = path("NEXO_MAIL_SANDBOX_DIR", data["sandbox_dir"], File.join(state_home, APP, "sandbox"))

    # --- Parsed config (memoized) --------------------------------------------
    def data
      @data ||= load
    end

    def load
      raw = File.exist?(config_file) ? TomlRB.parse(File.read(config_file)) : {}
      interpolate(raw)
    end

    def reload!
      @data = nil
      data
    end

    # --- Models ---------------------------------------------------------------
    def models
      Array(data["models"]).map do |m|
        Model.new(alias: m["alias"], provider: m["provider"], model: m["model"],
          api_base: m["api_base"], api_key: m["api_key"])
      end
    end

    # The model to run: the CLI alias, else NEXO_MAIL_MODEL, else the first defined.
    def active_model(cli_alias = nil)
      wanted = cli_alias || env("NEXO_MAIL_MODEL")
      list = models
      if list.empty?
        raise NexoMail::Error, "No models configured. Edit #{config_file} and add a [[models]] entry."
      end
      return list.first unless wanted

      list.find { |m| m.alias == wanted } ||
        raise(NexoMail::Error, "Unknown model alias #{wanted.inspect}. Configured: #{list.map(&:alias).join(", ")}")
    end

    def model_configured? = !models.empty?

    # --- Services -------------------------------------------------------------
    def gmail_address = val("NEXO_MAIL_GMAIL_ADDRESS", data.dig("services", "gmail", "address"))
    def gmail_app_password = val("NEXO_MAIL_GMAIL_APP_PASSWORD", data.dig("services", "gmail", "app_password"))

    def apple_mail_mcp_command
      val("NEXO_MAIL_APPLE_MAIL_MCP_COMMAND", data.dig("services", "apple_mail", "mcp_command"), "apple-mail-mcp")
    end

    # --- Theme ----------------------------------------------------------------
    def theme_flavor = val("NEXO_MAIL_THEME_FLAVOR", data.dig("theme", "flavor"), "mocha")

    # --- Prompt fragments -----------------------------------------------------
    # Contents of <prompts_dir>/<key>.md if present, else nil.
    def prompt_fragment(key)
      return nil if key.to_s.empty?

      path = File.join(prompts_dir, "#{key}.md")
      File.exist?(path) ? File.read(path) : nil
    end

    # --- Helpers --------------------------------------------------------------
    # First non-empty of ENV[name], config value, default (or nil).
    def val(env_name, value, default = nil)
      [env(env_name), value, default].map { |v| blank?(v) ? nil : v }.compact.first
    end

    def path(env_name, value, default)
      File.expand_path(val(env_name, value, default))
    end

    def env(name) = ENV[name]

    def blank?(v) = v.nil? || (v.is_a?(String) && v.strip.empty?)

    # Recursively resolve ${VAR} / ${VAR:-fallback} in every string leaf.
    def interpolate(obj)
      case obj
      when Hash then obj.transform_values { |v| interpolate(v) }
      when Array then obj.map { |v| interpolate(v) }
      when String then obj.gsub(/\$\{(\w+)(?::-([^}]*))?\}/) { ENV[Regexp.last_match(1)] || Regexp.last_match(2) || "" }
      else obj
      end
    end
  end
end
