# frozen_string_literal: true

module NexoMail
  module Workflows
    # Orchestration only — the Ruby here decides WHICH agents run and in WHAT order;
    # every artifact (per-source extraction, digest.json, inbox-digest.md,
    # dashboard.html, the snapshot) is produced by an agent writing into the shared
    # workspace. The workflow reads no mail, parses no JSON, and renders nothing.
    #
    # Pipeline:
    #   1. source agents (parallel)  → apple-mail.json / gmail.json / hey.json
    #   2. synthesize agent          → digest.json + inbox-digest.md
    #   3. publisher agent           → dashboard.html
    #   4. archivist agent           → snapshot + prune (via tools)
    #
    # Bulletproof: an unavailable source is skipped up front (with a reason); a source
    # that errors mid-run degrades to "no file"; and each later stage is best-effort,
    # so a failing synthesis/publisher/archivist never sinks the whole run.
    class MultiInboxTriage < Nexo::Workflow
      # display name => [agent class, extraction filename]
      SOURCES = {
        "Apple Mail" => [Agents::AppleMailSource, "apple-mail.json"],
        "Gmail" => [Agents::GmailSource, "gmail.json"],
        "HEY" => [Agents::HeySource, "hey.json"]
      }.freeze

      def call(payload)
        stamp = (payload || {})[:generated_at] || Time.now.utc

        available, skipped = partition_sources
        skipped.each { |name, reason| emit(:source_skipped, source: name, reason: reason) }

        produced = fan_out_sources(available)
        return {sources: [], skipped: skipped, files: []} if produced.empty?

        drive_agent(Agents::Synthesize, "synthesis", synthesis_prompt(produced, stamp))
        drive_agent(Agents::Publisher, "publisher", publisher_prompt)
        drive_agent(Agents::Archivist, "archivist", archivist_prompt)

        {sources: produced.keys, skipped: skipped, files: produced.values,
         snapshot: Snapshots.list.first}
      end

      private

      # ---- stage 1: source extraction (parallel) -------------------------------

      # Triage the available sources concurrently — their LLM round-trips overlap in
      # one async reactor. Each writes its own file, so no write contention. Returns
      # { display name => filename } for the sources that actually wrote a file.
      # Falls back to sequential when `async` is absent.
      def fan_out_sources(sources)
        return {} if sources.empty?

        pairs =
          begin
            Nexo.concurrent(max_in_flight: sources.size) do |c|
              sources.each { |name, (klass, file)| c.add { extract_source(name, klass, file) } }
            end
          rescue Nexo::MissingDependencyError => e
            emit(:async_unavailable, error: e.message)
            sources.map { |name, (klass, file)| extract_source(name, klass, file) }
          end
        pairs.compact.to_h
      end

      # Run one source agent to write its extraction file. Returns [name, file] when
      # the file was written, else nil (a failed source drops out). Never raises.
      def extract_source(name, klass, file)
        started = clock
        emit(:source_started, source: name, file: file)
        agent = klass.new(cwd: Config.sandbox_dir)
        agent.prompt(
          "Triage this inbox per the skills, then write the JSON array of items to " \
          "the file `#{file}` in the workspace.",
          max_turns: 30
        ) { |type, payload| forward_event(name, type, payload) }

        if File.exist?(File.join(Config.sandbox_dir, file))
          emit(:source_done, source: name, ms: ms_since(started))
          [name, file]
        else
          emit(:source_failed, source: name, error: "no extraction file written", ms: ms_since(started))
          nil
        end
      rescue => e
        emit(:source_failed, source: name, error: e.message, ms: ms_since(started))
        nil
      ensure
        agent&.close
      end

      # ---- stages 2–4: one agent each, best-effort -----------------------------

      # Run a single downstream agent, forwarding its events; a failure is logged and
      # swallowed so the pipeline continues with whatever the earlier stages produced.
      def drive_agent(klass, tag, prompt)
        started = clock
        emit(:"#{tag}_started")
        agent = klass.new(cwd: Config.sandbox_dir)
        agent.prompt(prompt, max_turns: 12) { |type, payload| forward_event(tag, type, payload) }
        emit(:"#{tag}_done", ms: ms_since(started))
      rescue => e
        emit(:"#{tag}_failed", error: e.message, ms: ms_since(started))
      ensure
        agent&.close
      end

      def synthesis_prompt(produced, stamp)
        files = produced.values.map { |f| "`#{f}`" }.join(", ")
        "The per-source extraction files in the workspace are: #{files}. The run " \
          "timestamp is #{stamp.iso8601} (display: #{stamp.strftime("%A, %-d %B %Y · %H:%M UTC")}). " \
          "Build the digest per the skill: write `digest.json` and `inbox-digest.md`."
      end

      # The Publisher pulls the render script + template from the CONFIGURED paths
      # (Config.dashboard_renderer/template — default: the seeded skill assets,
      # overridable via [dashboard] in config.toml) and renders in one shell call.
      # digest.json is read from the workspace; dashboard.html is written there.
      def publisher_prompt
        renderer = Config.dashboard_renderer
        template = Config.dashboard_template
        "Render the dashboard per the dashboard_designer skill, with the shell tool. " \
          "Run exactly:\n\n" \
          "  #{Config.dashboard_ruby} #{renderer.inspect} digest.json #{template.inspect} dashboard.html\n\n" \
          "Then confirm in one line. Do not hand-write the HTML."
      end

      def archivist_prompt
        "Archive this run's artifacts, then prune old snapshots keeping the newest " \
          "#{Config.snapshots_keep}."
      end

      # ---- source partitioning (orchestration decision) ------------------------

      def partition_sources
        available = {}
        skipped = {}
        SOURCES.each do |name, (klass, file)|
          reason = safe_availability(klass)
          reason ? (skipped[name] = reason) : (available[name] = [klass, file])
        end
        [available, skipped]
      end

      def safe_availability(klass)
        klass.availability
      rescue => e
        emit(:availability_check_failed, source: klass.name, error: e.message)
        nil
      end

      # ---- helpers -------------------------------------------------------------

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def ms_since(t0) = ((clock - t0) * 1000).round

      # Mirror an agent event into the workflow log with a compact, tagged shape.
      def forward_event(source, type, payload)
        data =
          case type
          when :tool_call then {source: source, tool: payload.respond_to?(:name) ? payload.name : payload.to_s}
          when :tool_result then {source: source, result: payload.to_s[0, 200]}
          else {source: source, info: payload.to_s[0, 200]}
          end
        emit(:"agent_#{type}", **data)
      end
    end
  end
end
