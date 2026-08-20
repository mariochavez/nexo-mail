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
      return prune_snapshots(opts[:prune]) if opts.key?(:prune)

      configure_model!(@cli_model)
      opts[:resume] ? resume(opts[:resume]) : triage
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
      # Tool concurrency goes through NEXO's setting (nexo_ai >= 0.8.1), which applies
      # it to each chat AFTER the tools are attached — every `with_tools` call resets a
      # chat's concurrency, so setting it globally on RubyLLM first is silently undone
      # by Nexo's own tool wiring.
      Nexo.configure do |c|
        c.skills_path = Config.skills_dir
        c.tool_concurrency = Config.tool_concurrency
        # Durability for a CLI. Everything that outlives the process — the run's
        # checkpoints, its suspended state, its recorded artifacts — is read back
        # from the run store, and Nexo's default one is in-memory. One line makes
        # `--resume` possible at all.
        c.run_store = Nexo::RunStore::Disk.new(dir: Config.runs_dir)
      end
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
        o.on("--resume [RUN_ID]", "Resume a suspended run (default: the most recent one)") { |v| opts[:resume] = v || :last }
        o.on("--prune-snapshots [KEEP]", Integer, "Delete old run snapshots, keeping the newest KEEP (default #{Config.snapshots_keep})") { |v| opts[:prune] = v }
        o.on("-h", "--help", "Show help and how to configure everything") { print_help }
      end.parse!(argv)
      opts
    rescue OptionParser::ParseError => e
      warn "#{e.message}\nTry: nexo-triage --help"
      exit 1
    end

    # ---- The run ------------------------------------------------------------

    def triage = drive("Triaging inboxes") { Workflows::MultiInboxTriage.run }

    # Continue a run the workflow paused (it read every inbox, then failed to build
    # the digest). Re-entering #call skips the extraction checkpoint, so this costs
    # a synthesis, not three inboxes. Only possible because runs persist to disk —
    # see the run_store line in #configure_model!.
    def resume(which)
      run = (which == :last) ? runs.all.find(&:suspended?) : runs.find(which.to_s)
      unless run&.suspended?
        warn bad.render(run ? "✗ Run #{run.id} is #{run.status}, not suspended." : "✗ No suspended run to resume.")
        exit 1
      end

      puts "  #{dim.render("resuming #{run.id} — #{run.suspend_reason}")}"
      drive("Resuming") { Workflows::MultiInboxTriage.resume(run.id) }
    end

    # The banner, the spinner and the report, shared by a fresh run and a resume.
    def drive(label)
      puts
      puts header.render("Nexo Mail Agent — Apple Mail · Gmail · HEY")
      puts "  #{dim.render("model: #{@active_model.alias} · #{@active_model.model} (#{@active_model.provider})")}"
      puts

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = nil
      error = nil
      worker = Thread.new do
        result = yield
      rescue => e
        error = e
      end

      spin(worker, started, label)
      worker.join
      print "\r\e[K" # clear the spinner line

      if error
        warn bad.render("✗ Run failed: #{error.class}: #{error.message}")
        raise error
      end

      total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      report(result, total)
      trim_runs
    end

    # The configured run store — Nexo::RunStore::Disk, set in #configure_model!.
    def runs = Nexo::RunStore.default

    # Nexo never prunes run documents: retention is the host's policy, and each one
    # carries this run's artifacts. Keep the newest N, delete the rest. Best-effort.
    def trim_runs
      runs.all.drop(Config.runs_keep).each { |run| File.delete(run.path) if run.path }
    rescue
      nil
    end

    def spin(worker, started, label)
      frame = 0
      while worker.alive?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        print "\r#{brand.render(SPINNER[frame % SPINNER.size])} " \
              "#{label}…  #{dim.render("elapsed #{clock(elapsed)}")}   "
        $stdout.flush
        frame += 1
        sleep 0.1
      end
    end

    STAGE_LABELS = {"synthesis" => "digest", "publisher" => "dashboard", "archivist" => "archive"}.freeze

    def report(run, total)
      results, stages = outcomes(run)
      Sources.all.each { |descriptor| puts source_line(descriptor.name, results[descriptor.name]) }
      print_stage_breakdown(results, stages, total)

      # The synthesis agent wrote the terminal digest into the workspace; read it
      # back only to display (no parsing, no generation on the Ruby side).
      digest = read_artifact("inbox-digest.md")
      puts
      if digest && !digest.strip.empty?
        puts Glamour.render_with_style(digest, Theme.glamour_style(@flavor), width: [term_width, 100].min)
      else
        puts bad.render("No digest produced (run status: #{run.status}).")
      end
      print_artifacts(run)
      print_resume_hint(run)
    end

    # Where the wall clock actually went. The sources run CONCURRENTLY, so their
    # times do not add up — the stage costs the slowest one, and that is what is
    # shown. Each line also carries the number of model round trips it took, which
    # is the number to look at when a run is slow: a stage that doubled its calls is
    # a prompt problem, a stage that kept its calls and doubled its time is not.
    def print_stage_breakdown(results, stages, total)
      timed = results.values.select { |r| r[:ms] }
      rows = []
      unless timed.empty?
        rows << ["read inboxes", timed.map { |r| r[:ms] }.max, timed.sum { |r| r[:calls].to_i },
          "#{timed.size} in parallel"]
      end
      STAGE_LABELS.each do |key, label|
        stage = stages[key] or next
        rows << [label, stage[:ms], stage[:calls].to_i, (stage[:state] == :failed) ? "failed" : nil]
      end
      return if rows.empty?

      puts "  #{dim.render("─" * 40)}"
      rows.each do |label, ms, calls, note|
        puts "  #{brand.render(label.ljust(13))}#{dim.render(duration(ms).rjust(7))}" \
             "  #{dim.render("#{calls} call#{"s" unless calls == 1}".rjust(8))}" \
             "#{note && "  #{dim.render(note)}"}"
      end
      puts "  #{dim.render("─" * 40)}"
      puts "  #{brand.render("total".ljust(13))}#{dim.render(duration(total * 1000).rjust(7))}"
    end

    # Point the user at the two deliverables (dashboard + JSON) and this run's
    # snapshot — all authored by the agents into the workspace/state dirs.
    def print_artifacts(run)
      dash = artifact_path("dashboard.html")
      json = artifact_path("digest.json")
      snap = (run.result && (run.result[:snapshot] || run.result["snapshot"])) || Snapshots.list.first
      puts
      puts "  #{brand.render("dashboard")}  #{File.exist?(dash) ? dash : dim.render("(not produced)")}"
      puts "  #{brand.render("data")}       #{File.exist?(json) ? json : dim.render("(not produced)")}"
      puts "  #{brand.render("snapshot")}   #{snap || dim.render("(not written)")}"
      print_run_artifacts(run)
      puts "  #{dim.render("open the dashboard →")} #{dim.render("open #{dash}")}" if File.exist?(dash)
    end

    # What the run itself carries. Every agent DECLARES its outputs (`produces`) and
    # the workflow copies them onto the run record, so these bytes are durable
    # independently of the workspace — that is what a caller embedding this workflow
    # gets back, and what would survive an ephemeral (container) sandbox.
    def print_run_artifacts(run)
      arts = run.artifacts
      return if arts.nil? || arts.empty?

      names = arts.map { |a| "#{a["name"]} #{dim.render(size(Nexo::Workflow.artifact_body(a).bytesize))}" }
      puts "  #{brand.render("recorded")}   #{dim.render("#{arts.size} artifacts on the run —")} #{names.join(dim.render(", "))}"
    end

    def size(bytes) = (bytes < 1024) ? "#{bytes}B" : "#{(bytes / 1024.0).round}KB"

    # A suspended run is a NON-failure: the inboxes were read and are checkpointed,
    # only the digest is missing. Say how to pick it up rather than leaving the user
    # to rerun everything.
    def print_resume_hint(run)
      return unless run.respond_to?(:suspended?) && run.suspended?

      puts
      puts "  #{bad.render("paused")}     #{run.suspend_reason}"
      puts "  #{dim.render("the inboxes are already read — resume with →")} #{dim.render("nexo-triage --resume")}"
    end

    def artifact_path(name) = File.join(Config.sandbox_dir, name)
    def read_artifact(name) = ((p = artifact_path(name)) && File.exist?(p)) ? File.read(p) : nil

    # Everything the report needs, read back out of the run's own event log: the
    # per-source outcome, the downstream stage timings, and the number of model
    # round trips each stage took. The round-trip count is the diagnostic that
    # matters — a stage's wall clock is round trips times whatever the provider is
    # charging per call today, and only the first of those is ours to fix.
    def outcomes(run)
      results = {}
      stages = {}
      calls = Hash.new(0)
      Nexo::Workflow.logs(run.id) do |ev|
        # emit() stores the data hash with the keys it was called with (symbols
        # here); the in-memory store returns them verbatim (a persisted store would
        # JSON-stringify them). Symbolize so both shapes read the same.
        d = (ev["data"] || ev[:data] || {}).transform_keys(&:to_sym)
        type = (ev["type"] || ev[:type]).to_s
        calls[d[:source]] += 1 if type == "agent_tool_call"
        case type
        when "source_done" then results[d[:source]] = {state: :ok, ms: d[:ms]}
        when "source_failed" then results[d[:source]] = {state: :failed, ms: d[:ms], detail: d[:error]}
        when "source_skipped" then results[d[:source]] = {state: :skipped, detail: d[:reason]}
        when /\A(synthesis|publisher|archivist)_(done|failed)\z/
          stages[$1] = {state: ($2 == "done") ? :ok : :failed, ms: d[:ms], detail: d[:error]}
        end
      end
      results.each { |name, r| r[:calls] = calls[name] }
      stages.each { |name, r| r[:calls] = calls[name] }
      [results, stages]
    end

    def source_line(name, r)
      r ||= {state: :unknown}
      label = brand.render(name.ljust(11))
      case r[:state]
      when :ok then "  #{ok.render("✓")} #{label} #{dim.render(duration(r[:ms]).rjust(7))}  #{dim.render("#{r[:calls]} call#{"s" unless r[:calls] == 1}")}"
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
      Sources.all.each do |descriptor|
        reason = descriptor.available?
        status = reason ? "#{dim.render("⊘")} #{dim.render(reason)}" : ok.render("✓ ready")
        puts "  #{brand.render(descriptor.name.ljust(11))} #{status}"
      end
      print_sandbox_check
      puts
      exit 0
    end

    # Ask the sandbox what it actually has, and check it against what the Publisher
    # DECLARES it needs (Agents::Publisher.requires). This is the same probe Nexo
    # runs before that agent's first turn — surfacing it here turns a mid-run "ruby:
    # command not found" into a preflight line, which matters because the sandbox
    # shell runs with a narrowed PATH and a version-managed ruby often is not on it.
    # Purely diagnostic: nothing here is fatal.
    def print_sandbox_check
      required = Agents::Publisher.requires[:commands]
      # Probe the SAME sandbox the Publisher declares, so `[dashboard] sandbox =
      # "docker"` checks the image rather than your host. One declaration, one probe.
      box = Nexo::Sandboxes.resolve(Agents::Publisher.sandbox, cwd: Config.sandbox_dir)
      where = Config.dashboard_containerized? ? "#{Config.dashboard_sandbox} · #{Config.dashboard_image}" : Config.sandbox_dir
      env = box.environment(commands: required.keys)
      puts
      puts "  #{brand.render("sandbox".ljust(11))} #{dim.render(where)}"
      if env[:error]
        puts "  #{" " * 11} #{bad.render("✗ could not inspect: #{env[:error]}")}"
        return
      end

      required.each { |name, want| puts "  #{" " * 11} #{command_line(name, want, env[:commands][name.to_s])}" }
      puts "  #{" " * 11} #{dim.render("locale #{env[:locale] || "(unset)"}")}"
      gaps = box.respond_to?(:hardening_gaps) ? box.hardening_gaps : []
      gaps.each { |gap| puts "  #{" " * 11} #{dim.render("⚠ #{gap}")}" }
    rescue => e
      puts "  #{brand.render("sandbox".ljust(11))} #{dim.render("probe unavailable: #{e.message}")}"
    ensure
      box.close if box.respond_to?(:close)
    end

    # One "does the sandbox have this, at a good enough version" line.
    def command_line(name, want, found)
      label = File.basename(name.to_s)
      unless found
        hint = if Config.dashboard_containerized?
          "the #{Config.dashboard_image} image does not ship one; pick an image that does"
        elsif name.to_s.start_with?("/")
          "no such executable there"
        else
          "pin [dashboard] ruby to an absolute path"
        end
        return bad.render("✗ #{name} not reachable from the sandbox shell — #{hint}")
      end

      version = found[:version].to_s
      good = version.empty? || Gem::Requirement.new(want.to_s).satisfied_by?(Gem::Version.new(version))
      detail = dim.render([version, found[:path]].reject { |v| v.to_s.empty? }.join(" "))
      good ? "#{ok.render("✓")} #{label} #{detail}" : bad.render("✗ #{label} #{version} does not satisfy #{want}")
    rescue ArgumentError
      "#{ok.render("✓")} #{label} #{dim.render(found[:path])}"
    end

    # ---- --prune-snapshots --------------------------------------------------

    # Pruning is agent-driven too: the Archivist decides the calls, the bounded
    # prune_snapshots tool does the deletion. The CLI only wires the model and shows
    # the before/after count (a plain directory listing — no snapshot logic here).
    def prune_snapshots(keep)
      keep = Config.snapshots_keep if keep.nil?
      configure_model!(@cli_model)
      puts header.render("Nexo Mail Agent — snapshots")
      puts "  #{dim.render("dir: #{Snapshots.dir}")}"
      before = Snapshots.list.size

      agent = Agents::Archivist.new(cwd: Config.sandbox_dir)
      agent.prompt("Prune old snapshots, keeping the newest #{keep}. Do not archive.", max_turns: 6)
      agent.close

      after = Snapshots.list.size
      puts
      puts "  #{brand.render("kept".ljust(9))} #{ok.render(after.to_s)} (of #{before})"
      puts "  #{brand.render("removed".ljust(9))} #{(before - after).zero? ? dim.render("none") : bad.render((before - after).to_s)}"
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
      note "Triage Apple Mail, Gmail & HEY into one briefing: a digest.json + a"
      note "self-contained dashboard.html. Agents & skills do the work; read-only mail."

      section "USAGE"
      line "nexo-triage [options]"

      section "OPTIONS"
      line "-m, --model ALIAS        Use a configured model by alias (default: the first)"
      line "    --theme FLAVOR        #{Theme.flavors.join(" | ")} (default from config)"
      line "    --check               Preflight: which model + services are ready"
      line "    --resume [RUN_ID]     Continue a paused run (default: the most recent) without re-reading the inboxes"
      line "    --prune-snapshots [N] Prune run snapshots, keeping the newest N (default #{Config.snapshots_keep})"
      line "-h, --help                This help"

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

      section "OUTPUT"
      line "digest.json     the canonical data (built by the synthesis agent)"
      line "dashboard.html  a self-contained briefing (built by the publisher agent)"
      line "inbox-digest.md the terminal digest · in #{Config.sandbox_dir}"
      line "snapshots       each run archived under #{Config.snapshots_dir}"
      line "runs            run history under #{Config.runs_dir} (newest #{Config.runs_keep} kept; what --resume reads)"

      section "MORE"
      note "Skills:  #{Config.skills_dir}"
      note "  email_triage · financial_summary · interest_radar (extraction),"
      note "  inbox_synthesis (digest), dashboard_designer (HTML), snapshot_keeper."
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

    # Sub-second in ms, then seconds, then minutes. A ten-minute stage rendered as
    # "612.4s" is a number you have to do arithmetic on to understand.
    def duration(ms)
      ms = ms.to_i
      return "#{ms}ms" if ms < 1000
      return format("%.1fs", ms / 1000.0) if ms < 60_000

      format("%dm %02ds", ms / 60_000, (ms % 60_000) / 1000)
    end

    def section(title) = puts("\n#{brand.render(title)}")
    def line(text) = puts("  #{text}")
    def note(text) = puts("  #{dim.render(text)}")
  end
end
