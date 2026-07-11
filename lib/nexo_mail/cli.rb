# frozen_string_literal: true

require "io/console"
require "optparse"
require "lipgloss"
require "glamour"

module NexoMail
  # The command-line entry point: first-run bootstrap, option parsing, runtime
  # configuration (theme, logging, selected model), and the styled run.
  class CLI
    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    def self.run(argv = ARGV) = new.run(argv)

    def run(argv)
      # A native gem (lipgloss/glamour) sets $VERBOSE = nil on load, which turns
      # Kernel#warn into a no-op. Restore it so our error output actually prints.
      $VERBOSE = false if $VERBOSE.nil?

      Bootstrap.ensure!

      # Set a palette up front so --help/--check (handled during parse) can style.
      set_theme(Config.theme_flavor)
      opts = parse(argv)
      set_theme(opts[:theme]) if opts[:theme] # --theme refines it

      @cli_model = opts[:model]
      configure_logging

      return print_check if opts[:check]

      configure_model!(@cli_model)
      triage
    rescue NexoMail::Error => e
      warn bad.render("✗ #{e.message}")
      exit 1
    end

    private

    def set_theme(flavor)
      @flavor = Theme.resolve(flavor)
      @palette = Theme.palette(@flavor)
    end

    # ---- Runtime configuration ----------------------------------------------

    def configure_logging
      logger = Logger.new(ENV["RUBYLLM_WIRE"] ? $stdout : File::NULL)
      logger.level = ENV["RUBYLLM_WIRE"] ? Logger::DEBUG : Logger::FATAL
      RubyLLM.configure { |c| c.logger = logger }
      if RubyLLM::MCP.respond_to?(:configure)
        RubyLLM::MCP.configure { |c| c.logger = logger }
      elsif RubyLLM::MCP.respond_to?(:config)
        RubyLLM::MCP.config.logger = logger
      end
    end

    # Point RubyLLM + Nexo at the selected model. Only one model is active per run,
    # so global mutation is correct (no ruby_llm Context needed).
    def configure_model!(cli_alias)
      model = @active_model = Config.active_model(cli_alias)
      RubyLLM.configure do |c|
        base_setter = "#{model.provider}_api_base="
        key_setter = "#{model.provider}_api_key="
        c.public_send(base_setter, model.api_base) if c.respond_to?(base_setter) && !model.api_base.to_s.empty?
        c.public_send(key_setter, model.api_key) if c.respond_to?(key_setter) && !model.api_key.to_s.empty?
      end
      Nexo.configure { |c| c.skills_path = Config.skills_dir }
      Nexo.config.default_model = model.model
      Agents::SourceAgent.configure_model!(model)
    end

    def parse(argv)
      opts = {}
      OptionParser.new do |o|
        o.banner = "Usage: nexo-triage [options]"
        o.on("-m", "--model ALIAS", "Use the configured model with this alias (default: first)") { |v| opts[:model] = v }
        o.on("--theme FLAVOR", Theme.flavors, "Catppuccin flavor: #{Theme.flavors.join(", ")}") { |v| opts[:theme] = v }
        o.on("--check", "Preflight only: which model + services are ready") { opts[:check] = true }
        o.on("-h", "--help", "Show help and how to configure everything") { print_help }
      end.parse!(argv)
      opts
    rescue OptionParser::ParseError => e
      warn "#{e.message}\nTry: nexo-triage --help"
      exit 1
    end

    # ---- The run ------------------------------------------------------------

    def triage
      puts
      puts header.render("Nexo Mail Agent — Apple Mail · Gmail · HEY")
      puts "  #{dim.render("model: #{@active_model.alias} · #{@active_model.model} (#{@active_model.provider})")}"
      puts

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = nil
      error = nil
      worker = Thread.new do
        result = Workflows::MultiInboxTriage.run
      rescue => e
        error = e
      end

      spin(worker, started)
      worker.join
      print "\r\e[K" # clear the spinner line

      if error
        warn bad.render("✗ Run failed: #{error.class}: #{error.message}")
        raise error
      end

      total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      report(result, total)
    end

    def spin(worker, started)
      frame = 0
      while worker.alive?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        print "\r#{brand.render(SPINNER[frame % SPINNER.size])} " \
              "Triaging inboxes…  #{dim.render("elapsed #{clock(elapsed)}")}   "
        $stdout.flush
        frame += 1
        sleep 0.1
      end
    end

    def report(run, total)
      results = outcomes(run)
      Workflows::MultiInboxTriage::SOURCES.each_key { |name| puts source_line(name, results[name]) }
      puts "  #{dim.render("─" * 24)}"
      puts "  #{brand.render("total".ljust(13))}#{dim.render(clock(total))}"

      art = run.artifacts.find { |a| (a["name"] || a[:name]) == "inbox-digest.md" }
      digest = art && (art["content"] || art[:content])
      puts
      if digest && !digest.strip.empty?
        puts Glamour.render_with_style(digest, Theme.glamour_style(@flavor), width: [term_width, 100].min)
        puts dim.render("Saved to #{File.join(Config.sandbox_dir, "inbox-digest.md")}")
      else
        puts bad.render("No digest produced (run status: #{run.status}).")
      end
    end

    def outcomes(run)
      results = {}
      Nexo::Workflow.logs(run.id) do |ev|
        # emit() stores the data hash with the keys it was called with (symbols
        # here); the in-memory store returns them verbatim (a persisted store would
        # JSON-stringify them). Symbolize so both shapes read the same.
        d = (ev["data"] || ev[:data] || {}).transform_keys(&:to_sym)
        case (ev["type"] || ev[:type]).to_s
        when "source_done" then results[d[:source]] = {state: :ok, ms: d[:ms]}
        when "source_failed" then results[d[:source]] = {state: :failed, ms: d[:ms], detail: d[:error]}
        when "source_skipped" then results[d[:source]] = {state: :skipped, detail: d[:reason]}
        end
      end
      results
    end

    def source_line(name, r)
      r ||= {state: :unknown}
      label = brand.render(name.ljust(11))
      case r[:state]
      when :ok then "  #{ok.render("✓")} #{label} #{dim.render(duration(r[:ms]))}"
      when :failed then "  #{bad.render("✗")} #{label} #{dim.render(duration(r[:ms]))}  #{bad.render("failed: #{r[:detail].to_s[0, 60]}")}"
      when :skipped then "  #{dim.render("⊘")} #{label} #{dim.render("skipped — #{r[:detail]}")}"
      else "  #{dim.render("• #{name} — no result")}"
      end
    end

    # ---- --check ------------------------------------------------------------

    def print_check
      puts header.render("Nexo Mail Agent — preflight")
      puts
      puts "  #{brand.render("model".ljust(11))} #{model_check}"
      Workflows::MultiInboxTriage::SOURCES.each do |name, (klass, _)|
        reason = klass.availability
        status = reason ? "#{dim.render("⊘")} #{dim.render(reason)}" : ok.render("✓ ready")
        puts "  #{brand.render(name.ljust(11))} #{status}"
      end
      puts
      exit 0
    end

    def model_check
      return bad.render("none configured — add [[models]] to #{Config.config_file}") unless Config.model_configured?

      m = Config.active_model(@cli_model)
      extra = (Config.models.size > 1) ? dim.render(" (#{Config.models.size} configured)") : ""
      "#{ok.render(m.alias)} #{dim.render("#{m.model} · #{m.provider}")}#{extra}"
    rescue NexoMail::Error => e
      bad.render(e.message)
    end

    # ---- --help -------------------------------------------------------------

    def print_help
      puts header.render("Nexo Mail Agent")
      note "Triage Apple Mail, Gmail & HEY into one prioritized digest. Read-only."

      section "USAGE"
      line "nexo-triage [options]"

      section "OPTIONS"
      line "-m, --model ALIAS   Use a configured model by alias (default: the first)"
      line "    --theme FLAVOR   #{Theme.flavors.join(" | ")} (default from config)"
      line "    --check          Preflight: which model + services are ready"
      line "-h, --help           This help"

      section "CONFIG — #{Config.config_file}"
      note "Edit the TOML config (created on first run). Every value can use"
      note "${VAR} interpolation, and every setting has a NEXO_MAIL_* env override."

      section "MODELS (required — no default)"
      line "Add one or more [[models]] to config.toml; the first is used unless --model:"
      line "  [[models]]"
      line "  alias = \"local\"; provider = \"ollama\"; model = \"llama3.1\""
      line "  api_base = \"http://localhost:11434/v1\"; api_key = \"\""

      section "APPLE MAIL — apple-mail-mcp (local MCP server)"
      line "pipx install apple-mail-mcp"
      line "Grant Full Disk Access to your terminal (System Settings → Privacy)."
      line "apple-mail-mcp init            # writes ~/.apple-mail-mcp/config.toml"
      line "apple-mail-mcp index --verbose # build the search index"

      section "GMAIL — read-only IMAP with an App Password (no gcloud)"
      line "1. Enable 2-Step Verification on the Google account."
      line "2. Create an App Password: https://myaccount.google.com/apppasswords"
      line "3. Set [services.gmail] address/app_password in config.toml"
      line "   (or NEXO_MAIL_GMAIL_ADDRESS / NEXO_MAIL_GMAIL_APP_PASSWORD)."

      section "HEY — the Basecamp hey CLI"
      line "Install (Go 1.26+): git clone https://github.com/basecamp/hey-cli && go install ./cmd/..."
      line "Authenticate:  hey auth login"

      section "MORE"
      note "Skills:  #{Config.skills_dir}  (edit email_triage/SKILL.md to retune triage)"
      note "Prompts: #{Config.prompts_dir}  (drop common.md / gmail.md / … to extend agents)"
      note "Any unconfigured service is skipped; the run continues. RUBYLLM_WIRE=1 shows logs."
      puts
      exit 0
    end

    # ---- Styles (lipgloss, driven by the active palette) --------------------

    def style = Lipgloss::Style.new
    def header = style.bold(true).foreground(@palette[:base]).background(@palette[:mauve]).padding(0, 2)
    def brand = style.foreground(@palette[:mauve]).bold(true)
    def dim = style.foreground(@palette[:overlay1])
    def ok = style.foreground(@palette[:green]).bold(true)
    def bad = style.foreground(@palette[:red]).bold(true)

    def term_width = IO.console&.winsize&.last || 80
    def clock(seconds) = format("%02d:%02d", (seconds / 60).to_i, (seconds % 60).to_i)

    def duration(ms)
      ms = ms.to_i
      (ms < 1000) ? "#{ms}ms" : format("%.1fs", ms / 1000.0)
    end

    def section(title) = puts("\n#{brand.render(title)}")
    def line(text) = puts("  #{text}")
    def note(text) = puts("  #{dim.render(text)}")
  end
end
