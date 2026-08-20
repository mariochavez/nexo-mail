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
      # The workflow shares the agents' workspace, so `artifact(path:)` reads the
      # very files they wrote. `cwd` is a lazy READER override, not the macro's
      # setter: Config is not loaded until CLI.run, and Nexo resolves the sandbox on
      # first touch, so reading it here defers the lookup to exactly the right
      # moment. Nothing else in this class touches the filesystem.
      sandbox :local
      def self.cwd = Config.sandbox_dir

      def call(payload)
        stamp = (payload || {})[:generated_at] || Time.now.utc

        available, skipped = partition_sources
        skipped.each { |name, reason| emit(:source_skipped, source: name, reason: reason) }

        # The expensive half: three inboxes, minutes of model time. Behind a
        # checkpoint it is paid for ONCE per run — a `--resume` after a failed
        # synthesis re-enters #call from the top and gets this back from the run's
        # state instead of reading every inbox again. (Durable only because the CLI
        # points Nexo at a Disk run store; on the in-memory default the run, and this,
        # die with the process.)
        produced = checkpoint(:extract) { fan_out_sources(available) }
        return {sources: [], skipped: skipped, files: []} if produced.empty?

        drive_agent(Agents::Synthesize, "synthesis", synthesis_prompt(produced, stamp))
        # A run that read every inbox and then failed to build the digest is worth
        # pausing rather than burying: "suspended" is a non-failure the CLI can offer
        # to resume, and resuming skips straight back to synthesis. Outside the
        # checkpoint, which is where suspend! belongs.
        suspend!(reason: "synthesis produced no #{DIGEST}") unless File.exist?(File.join(Config.sandbox_dir, DIGEST))
        drive_agent(Agents::Publisher, "publisher") { |agent| publisher_prompt(agent) }
        drive_agent(Agents::Archivist, "archivist", archivist_prompt)

        {sources: produced.keys, skipped: skipped, files: produced.values,
         artifacts: @run.artifacts.map { |a| a["name"] }.uniq,
         snapshot: Snapshots.list.first}
      end

      private

      # ---- stage 1: source extraction (parallel) -------------------------------

      # Triage the available sources concurrently — their LLM round-trips overlap in
      # one async reactor. Each writes its own file, so no write contention. Takes a
      # { display name => descriptor } hash; returns { name => filename } for the
      # sources that actually wrote a file. Falls back to sequential when `async` is
      # absent.
      def fan_out_sources(sources)
        return {} if sources.empty?

        pairs =
          begin
            Nexo.concurrent(max_in_flight: sources.size) do |c|
              sources.each_value { |descriptor| c.add { extract_source(descriptor) } }
            end
          rescue Nexo::MissingDependencyError => e
            emit(:async_unavailable, error: e.message)
            sources.values.map { |descriptor| extract_source(descriptor) }
          end
        pairs.compact.to_h
      end

      # Run one source agent to write its extraction file. Returns [name, file] when
      # the file was written, else nil (a failed source drops out). Never raises.
      def extract_source(descriptor)
        started = clock
        name = descriptor.name
        file = descriptor.file
        emit(:source_started, source: name, file: file)
        agent = descriptor.build(cwd: Config.sandbox_dir)
        agent.prompt(
          "Triage this inbox per the skills, then write the JSON array of items to " \
          "the file `#{file}` in the workspace.",
          max_turns: 30
        ) { |type, payload| forward_event(name, type, payload) }

        if File.exist?(File.join(Config.sandbox_dir, file))
          record_artifact(file)
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
      # +prompt+ is either a ready string or a block taking the built agent — the
      # publisher needs the latter, because it stages the skill's files into that
      # agent's own sandbox before telling it what to run. A nil prompt means the
      # stage declined and already emitted why.
      def drive_agent(klass, tag, prompt = nil)
        started = clock
        emit(:"#{tag}_started")
        agent = klass.new(cwd: Config.sandbox_dir)
        text = block_given? ? yield(agent) : prompt
        return if text.nil?

        agent.prompt(text, max_turns: 12) { |type, payload| forward_event(tag, type, payload) }
        emit(:"#{tag}_done", ms: ms_since(started))
      rescue Nexo::EnvironmentError => e
        # The agent declared what its sandbox must provide (`requires`) and the
        # sandbox does not provide it. Distinct from a model/tool failure and worth
        # its own event: the fix is provisioning, not a retry.
        emit(:"#{tag}_failed", error: e.message, ms: ms_since(started), unmet: true)
      rescue => e
        emit(:"#{tag}_failed", error: e.message, ms: ms_since(started))
      ensure
        # Record whatever the agent DECLARED it produces, on every path — including
        # the failure paths above, because a stage that died after writing its file
        # still produced it. Nexo skips a declared artifact that was never written.
        collect_declared(agent, tag)
        agent&.close
      end

      # ---- artifacts (nexo_ai >= 0.9) -------------------------------------------

      # The one input the render stage needs, and the pipeline's canonical artifact.
      DIGEST = "digest.json"

      # Copy the agent's DECLARED outputs (`produces`) onto the run record. Nexo
      # reads each name through this workflow's sandbox and stores the bytes on the
      # run, so a deliverable outlives the workspace that held it — and so a caller
      # driving this workflow as a library gets the artifacts back without knowing
      # where on disk we happened to write them. Never fatal.
      def collect_declared(agent, tag)
        return unless agent

        collected = shares_workspace?(agent) ? collect_artifacts(agent) : import_artifacts(agent)
        emit(:artifacts_collected, stage: tag, names: collected.map { |a| a["name"] }) unless collected.empty?
      rescue => e
        emit(:artifact_skipped, stage: tag, error: e.message)
      end

      # Nexo's collect_artifacts resolves an agent's declared names through the
      # WORKFLOW's sandbox. That is right for every agent writing into the shared
      # workspace and wrong for one sandboxed elsewhere, so ask the agent itself.
      # Tolerant of a duck the way Nexo's own collect_artifacts is: anything that
      # cannot name its sandbox is assumed to write into the shared workspace.
      def shares_workspace?(agent)
        !agent.respond_to?(:sandbox) || agent.sandbox.is_a?(Nexo::Sandboxes::Local)
      end

      # Collection for a containerized agent, whose workspace ceases to exist the
      # moment the stage ends. Read each declared name through the agent's own
      # sandbox, record the bytes on the run, and mirror them into the shared
      # workspace so the later stages (the Archivist) and the CLI find them exactly
      # where a :local run would have left them.
      def import_artifacts(agent)
        return [] unless agent.class.respond_to?(:produces)

        agent.class.produces.filter_map do |name|
          body = agent.sandbox.read(name)
          sandbox.write(name, body)
          artifact(name, content: body)
        rescue => e
          emit(:artifact_skipped, name: name.to_s, error: e.message)
          nil
        end
      end

      # The source agents can't use `produces`: one EmailSource CLASS serves every
      # tool-based inbox, and the filename comes from the per-instance descriptor.
      # So record this one by path — the same verbatim, no-ERB copy `produces` uses
      # underneath. Never fatal: an unrecorded artifact must not fail a good run.
      def record_artifact(file)
        artifact(file, path: file)
      rescue => e
        emit(:artifact_skipped, file: file, error: e.message)
      end

      def synthesis_prompt(produced, stamp)
        files = produced.values.map { |f| "`#{f}`" }.join(", ")
        "The per-source extraction files in the workspace are: #{files}. The run " \
          "timestamp is #{stamp.iso8601} (display: #{stamp.strftime("%A, %-d %B %Y · %H:%M UTC")}). " \
          "Build the digest per the skill: write `digest.json` and `inbox-digest.md`."
      end

      # Stages the Publisher's skill resources INTO the sandbox, then builds the
      # render command against them. Everything the agent touches is therefore inside
      # the sandbox and reachable through Nexo's permission-gated read/glob tools —
      # skill files otherwise live outside it and are invisible to those tools.
      #
      # Which skill, and which files: entirely dynamic. The agent's own `skills`
      # declaration is the single source of truth, and ruby_llm-skills (via
      # Nexo::Skills) enumerates its scripts/ and assets/. Nothing here names a skill
      # or a filename. [dashboard] in config.toml still overrides either path, in
      # which case that absolute path is used as-is rather than staged.
      #
      # SECURITY — accepted tradeoff. The Publisher holds :write AND :shell, so a
      # staged script sits in space it can rewrite before executing; kept outside the
      # sandbox it could not be tampered with at all. Mitigation: we re-stage (and
      # overwrite) on EVERY run, immediately before the agent runs, so tampering can
      # never persist across runs. The residual window is one turn, by a script the
      # agent is told to run verbatim.
      def publisher_prompt(agent)
        emit(:publisher_sandbox, kind: Config.dashboard_sandbox, image: Config.dashboard_image)
        # An omitted hardening flag means WEAKER isolation than was asked for, so the
        # runtime reporting one is worth an event rather than a shrug.
        gaps = agent.sandbox.hardening_gaps if agent.sandbox.respond_to?(:hardening_gaps)
        emit(:publisher_hardening_gaps, gaps: gaps) if gaps && !gaps.empty?

        skill = Agents::Publisher.skills.first
        staged = stage_skill_resources(skill, agent.sandbox)
        renderer = in_workspace(Config.dashboard_renderer(skill) { staged[:scripts]&.first }, staged[:scripts]&.first)
        template = in_workspace(Config.dashboard_template(skill) { staged[:assets]&.first }, staged[:assets]&.first)
        unless renderer && template
          emit(:publisher_failed, error: "the #{skill} skill ships no #{renderer ? "asset" : "script"} to render with")
          return nil
        end
        return nil unless hand_over_inputs(agent)

        "Render the dashboard per the #{skill} skill, with the shell tool. Its script " \
          "and template have been staged into your workspace, so you can read or glob " \
          "them if you need to. Run exactly:\n\n" \
          "  #{publisher_ruby} #{renderer.inspect} digest.json #{template.inspect} dashboard.html\n\n" \
          "Then confirm in one line. Do not hand-write the HTML."
      end

      # `[dashboard] ruby` pins a HOST interpreter — the answer to a narrowed sandbox
      # PATH on :local. Inside a container that path does not exist; the image's own
      # ruby is the only one there, and choosing the image is how you choose it.
      def publisher_ruby = Config.dashboard_containerized? ? "ruby" : Config.dashboard_ruby

      # `[dashboard] template` / `renderer` override with an ABSOLUTE HOST path, which
      # a container cannot see. Fall back to the staged, workspace-relative copy and
      # say so, rather than emitting a render command that is certain to fail.
      def in_workspace(path, staged)
        return path unless Config.dashboard_containerized? && path.to_s.start_with?("/") && staged

        emit(:publisher_override_ignored, path: path.to_s, using: staged)
        staged
      end

      # Hand the stage its input. On :local digest.json is already in the shared
      # workspace and this is a no-op; a container starts with an empty one, so the
      # bytes are copied across. Sandbox to sandbox, reading from the workspace
      # rather than the run record: the file the previous stage wrote is the source
      # of truth, and the recorded artifact is a copy of it.
      def hand_over_inputs(agent)
        return true if shares_workspace?(agent)

        agent.sandbox.write(DIGEST, sandbox.read(DIGEST))
        true
      rescue => e
        emit(:publisher_failed, error: "could not hand #{DIGEST} to the render sandbox: #{e.message}")
        false
      end

      # Copies every file the skill ships into the sandbox, preserving the
      # scripts//assets/ layout so the agent can glob `scripts/*` the way the skill's
      # own prose describes. Returns workspace-relative paths grouped by kind.
      #
      # Nexo::Skills.materialize does this through the SANDBOX's own #write, so it
      # works on :local, :docker/:apple and :remote alike — a plain FileUtils.cp (what
      # this used to be) only ever worked on :local, and on a container it copied to a
      # host directory the agent could not see. Overwrites each run, which is what
      # bounds tampering with a staged script to a single turn. Never fatal.
      def stage_skill_resources(skill, sandbox)
        Nexo::Skills.materialize(skill, into: sandbox, kinds: %i[scripts assets])
      rescue => e
        emit(:staging_failed, skill: skill.to_s, error: e.message)
        {}
      end

      def archivist_prompt
        "Archive this run's artifacts, then prune old snapshots keeping the newest " \
          "#{Config.snapshots_keep}."
      end

      # ---- source partitioning (orchestration decision) ------------------------

      def partition_sources
        available = {}
        skipped = {}
        Sources.all.each do |descriptor|
          reason = safe_availability(descriptor)
          reason ? (skipped[descriptor.name] = reason) : (available[descriptor.name] = descriptor)
        end
        [available, skipped]
      end

      def safe_availability(descriptor)
        descriptor.available?
      rescue => e
        emit(:availability_check_failed, source: descriptor.name, error: e.message)
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
