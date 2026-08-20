# frozen_string_literal: true

module NexoMail
  # Loads and exposes the XDG TOML config. Precedence for every setting is
  # ENV (NEXO_MAIL_*) > config.toml value > built-in default, and any string value
  # in the TOML may reference an env var via ${VAR} or ${VAR:-fallback}.
  module Config
    APP = "nexo-mail"

    Model = Struct.new(:alias, :provider, :model, :api_base, :api_key)

    module_function

    # --- XDG locations --------------------------------------------------------
    def config_home = File.expand_path(env("XDG_CONFIG_HOME") || "~/.config")
    def state_home = File.expand_path(env("XDG_STATE_HOME") || "~/.local/state")
    def config_dir = File.join(config_home, APP)

    def config_file
      override = env("NEXO_MAIL_CONFIG")
      override ? File.expand_path(override) : File.join(config_dir, "config.toml")
    end

    def skills_dir = path("NEXO_MAIL_SKILLS_DIR", data["skills_dir"], File.join(config_dir, "skills"))
    def prompts_dir = path("NEXO_MAIL_PROMPTS_DIR", data["prompts_dir"], File.join(config_dir, "prompts"))
    def sandbox_dir = path("NEXO_MAIL_SANDBOX_DIR", data["sandbox_dir"], File.join(state_home, APP, "sandbox"))

    # Each run archives its artifacts (digest.json, dashboard.html, inbox-digest.md)
    # into a timestamped subdirectory here; `nexo-triage --prune-snapshots` trims them.
    def snapshots_dir = path("NEXO_MAIL_SNAPSHOTS_DIR", data["snapshots_dir"], File.join(state_home, APP, "snapshots"))

    # How many run snapshots to keep when pruning (newest wins). Default 20.
    def snapshots_keep
      val("NEXO_MAIL_SNAPSHOTS_KEEP", data["snapshots_keep"], "20").to_i
    end

    # --- Skill-bundled resources ----------------------------------------------
    # Skills may ship runnable files beside their prose — `scripts/`, `assets/`,
    # `references/` — which is ruby_llm-skills' own convention, not ours. Resolve
    # them THROUGH that layer (Nexo::Skills.find delegates to it) instead of
    # joining paths by hand, so a skill can rename its files, or a new
    # script-bearing skill can appear, with no code change here.
    #
    # Returns nil when the skill ships nothing of that kind — callers decide
    # whether that is fatal.
    def skill_script(skill, matching = nil) = skill_resource(skill, :scripts, matching)

    def skill_asset(skill, matching = nil) = skill_resource(skill, :assets, matching)

    # Every file of that kind the skill ships, sorted. Empty when it ships none or
    # the skill can't be resolved.
    def skill_files(skill, kind, matching = nil)
      files = Nexo::Skills.find(skill).public_send(kind).sort
      matching ? files.select { |f| File.basename(f).include?(matching.to_s) } : files
    rescue Nexo::Error, Nexo::MissingDependencyError
      []
    end

    def skill_resource(skill, kind, matching = nil)
      skill_files(skill, kind, matching).first
    end

    # The dashboard template + render script the Publisher runs. Both are AUTO-
    # RESOLVED from the skill the Publisher actually declares — nothing here names
    # the skill or the filenames. `[dashboard] template` / `renderer` in config.toml
    # (or NEXO_MAIL_DASHBOARD_*) override, which is how you restyle the dashboard
    # by pointing at your own HTML without touching the gem.
    # An explicit override is used as an ABSOLUTE path; otherwise the caller's block
    # supplies the fallback (the workspace-relative path of the staged resource),
    # which is returned as-is so the render command stays inside the sandbox.
    def dashboard_template(skill, &staged)
      resolve("NEXO_MAIL_DASHBOARD_TEMPLATE", data.dig("dashboard", "template"), skill_asset(skill), &staged)
    end

    def dashboard_renderer(skill, &staged)
      resolve("NEXO_MAIL_DASHBOARD_RENDERER", data.dig("dashboard", "renderer"), skill_script(skill), &staged)
    end

    def resolve(env_name, configured, resolved)
      override = val(env_name, configured)
      return File.expand_path(override) if override

      (block_given? ? yield : nil) || resolved
    end

    # The Ruby interpreter the Publisher uses to run the render script inside its
    # sandbox shell. Defaults to "ruby" (resolved on PATH); pin an absolute path
    # (e.g. a mise-managed Ruby) when the sandbox's narrowed PATH won't resolve it.
    def dashboard_ruby
      val("NEXO_MAIL_DASHBOARD_RUBY", data.dig("dashboard", "ruby"), "ruby")
    end

    # Which sandbox the Publisher renders in: "local" (default — the shared
    # workspace, same as every other agent) or "docker" / "apple" (a throwaway
    # container). The Publisher is the only agent holding :shell and it reaches no
    # mail, so it is the one stage that can be isolated at no cost to the pipeline.
    # An unknown value is an explicit error, never a silent fall back to the host.
    DASHBOARD_SANDBOXES = %w[local docker apple].freeze

    def dashboard_sandbox
      value = val("NEXO_MAIL_DASHBOARD_SANDBOX", data.dig("dashboard", "sandbox"), "local").to_s.strip.downcase
      return value if DASHBOARD_SANDBOXES.include?(value)

      raise NexoMail::Error,
        "[dashboard] sandbox must be one of #{DASHBOARD_SANDBOXES.join(", ")} (got #{value.inspect})"
    end

    def dashboard_containerized? = dashboard_sandbox != "local"

    # The image the containerized Publisher runs in. It needs nothing but a Ruby
    # interpreter — the render script is pure stdlib — so any ruby:* tag works.
    def dashboard_image
      val("NEXO_MAIL_DASHBOARD_IMAGE", data.dig("dashboard", "image"), "ruby:3.3-slim")
    end

    # --- Read shaping ---------------------------------------------------------
    # How much mail the source tools pull, and how much of each message they hand
    # the model. These are the ONLY real bound on a runaway read loop: the
    # workflow passes max_turns, but Nexo::Loops::RubyLLM accepts and ignores it.
    # Every value is clamped so a bad TOML entry cannot spawn 200 threads or
    # flood the context.
    def gmail_list_limit = read_int("NEXO_MAIL_GMAIL_LIST_LIMIT", "gmail_list_limit", 40, 1..200)

    def gmail_snippet_chars = read_int("NEXO_MAIL_GMAIL_SNIPPET_CHARS", "gmail_snippet_chars", 400, 0..2_000)

    def gmail_read_max_uids = read_int("NEXO_MAIL_GMAIL_READ_MAX_UIDS", "gmail_read_max_uids", 25, 1..100)

    def gmail_body_chars = read_int("NEXO_MAIL_GMAIL_BODY_CHARS", "gmail_body_chars", 4_000, 200..20_000)

    def hey_box_limit = read_int("NEXO_MAIL_HEY_BOX_LIMIT", "hey_box_limit", 40, 1..200)

    def hey_snippet_chars = read_int("NEXO_MAIL_HEY_SNIPPET_CHARS", "hey_snippet_chars", 200, 0..1_000)

    def hey_thread_max_ids = read_int("NEXO_MAIL_HEY_THREAD_MAX_IDS", "hey_thread_max_ids", 15, 1..50)

    def hey_body_chars = read_int("NEXO_MAIL_HEY_BODY_CHARS", "hey_body_chars", 4_000, 200..20_000)

    def hey_payload_max_chars = read_int("NEXO_MAIL_HEY_PAYLOAD_MAX_CHARS", "hey_payload_max_chars", 40_000, 4_000..200_000)

    # How many `hey` fan-out tasks one tool call may start. DEFAULT 1, because the
    # work is serial anyway: `hey` cannot run concurrently (it races on the macOS
    # keyring), so Tools::Hey::LOCK holds a mutex across every invocation and raising
    # this only queues fibers behind it. The lock — not this number — is the safety
    # invariant; see Tools::Hey for the measurements.
    def hey_concurrency = read_int("NEXO_MAIL_HEY_CONCURRENCY", "hey_concurrency", 1, 1..8)

    # How ruby_llm executes MULTIPLE tool calls emitted in a single assistant turn:
    # :fibers (default, via async — the same reactor the workflow already fans its
    # source agents out in), :threads, or off. Batched read tools mean a turn usually
    # carries one call, so this matters most when the model lists two inboxes or
    # reads and writes in the same turn.
    #
    # Safe by construction: every mail tool is stateless per call (a fresh IMAP
    # session, a fresh subprocess), and the one shared resource that cannot take
    # concurrency — the `hey` CLI — is serialized by Tools::Hey::LOCK regardless of
    # which caller reaches it.
    def tool_concurrency
      raw = val("NEXO_MAIL_TOOL_CONCURRENCY", data.dig("read", "tool_concurrency"), "fibers").to_s.strip.downcase
      %w[fibers threads].include?(raw) ? raw.to_sym : false
    end

    # Apple Mail's MCP get_email returns an UNTRUNCATED body — the largest single
    # context risk in the pipeline. Used by Agents::AppleMailSource to cap it.
    def apple_body_chars = read_int("NEXO_MAIL_APPLE_BODY_CHARS", "apple_body_chars", 4_000, 200..20_000)

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

    # A clamped integer read-shaping setting from [read] in config.toml. Same
    # ENV > TOML > default precedence as #val; the clamp is what keeps a typo
    # ("4000000" for "400") from flooding the context or the thread pool. A
    # non-numeric value falls back to the default rather than to #to_i's 0 —
    # otherwise "oops" would silently mean "disable snippets".
    def read_int(env_name, key, default, range)
      raw = val(env_name, data.dig("read", key), default).to_s.strip
      (raw.match?(/\A-?\d+\z/) ? raw.to_i : default).clamp(range.min, range.max)
    end

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
