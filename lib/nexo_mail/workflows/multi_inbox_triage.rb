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
    #   2. synthesize agent          → digest.json + inbox-digest.md — built in
    #                                    full, amended with the new items, or not
    #                                    run at all (DigestFile.plan)
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

        # The expensive half: three inboxes, minutes of model time, triaged
        # concurrently. Each source is its OWN checkpoint, saved the moment it
        # finishes — so it is paid for once per run, and a `--resume` after a crash
        # or a failed synthesis re-enters #call from the top, gets the finished
        # sources back from the run's state, and reads only an inbox that never
        # landed. (Durable only because the CLI points Nexo at a Disk run store; on
        # the in-memory default the run, and this, die with the process.)
        produced = checkpoint_all(available.transform_values { |source| -> { extract_source(source) } }).compact
        return {sources: [], skipped: skipped, files: []} if produced.empty?

        # Decided only now: the inboxes' commits are what say how much is waiting.
        # Which agents run is the one decision this class exists to make, and with
        # nothing new and a digest built today the answer is none of them.
        plan = DigestFile.plan!
        emit(:digest_plan, plan: plan, pending: DigestFile.pending)
        if plan == :current && File.exist?(File.join(Config.sandbox_dir, DASHBOARD))
          emit(:digest_current, built_on: DigestFile.built_on)
          return {sources: produced.keys, skipped: skipped, files: produced.values, unchanged: true,
                  snapshot: Snapshots.list.first}
        end

        unless plan == :current
          DigestFile.clear
          drive_agent(Agents::Synthesize, "synthesis", synthesis_prompt(produced, stamp, plan), max_turns: SYNTHESIS_TURNS.fetch(plan))
          # A run that read every inbox and then failed to save the digest is worth
          # pausing rather than burying: "suspended" is a non-failure the CLI can
          # offer to resume, and resuming skips straight back to synthesis. The
          # commit, not the file — `digest.json` survives from the run before, which
          # is how a failed synthesis used to pass for a finished one. The items it
          # was handed stay pending, so the resume is handed them again. Outside the
          # checkpoint, which is where suspend! belongs.
          suspend!(reason: "the digest was not saved") unless DigestFile.committed?
        end
        drive_agent(Agents::Publisher, "publisher") { |agent| publisher_prompt(agent) }
        drive_agent(Agents::Archivist, "archivist", archivist_prompt)

        {sources: produced.keys, skipped: skipped, files: produced.values,
         artifacts: @run.artifacts.map { |a| a["name"] }.uniq,
         snapshot: Snapshots.list.first}
      end

      private

      # ---- stage 1: source extraction (parallel) -------------------------------

      # Run one source agent to write its extraction file. Returns the file name when
      # it was written, else nil (a failed source drops out). Never raises — a
      # checkpoint step that raised would fail the whole run and take the other
      # sources with it.
      def extract_source(descriptor)
        started = clock
        name = descriptor.name
        file = descriptor.file
        emit(:source_started, source: name, file: file)
        agent = descriptor.build(cwd: Config.sandbox_dir)
        inbox = Ledger.inbox_file(file)
        Tools::CommitExtraction.clear(file)
        agent.prompt(
          "Triage the mail that is new in this inbox per the skills. Write the JSON " \
          "array of the items you extracted to `#{inbox}` in the workspace (`[]` if " \
          "nothing new arrived), then call commit_extraction with that file: it merges " \
          "them with what earlier runs kept and writes `#{file}`.",
          max_turns: 30
        ) { |type, payload| forward_event(name, type, payload) }

        # The commit, not the file: `file` survives in the workspace from the run
        # before, so its existence proves nothing about this one. An uncommitted
        # source drops out, and its mail is offered again next run.
        if Ledger.for_file(file).committed?
          record_artifact(file)
          emit(:source_done, source: name, ms: ms_since(started))
          file
        else
          emit(:source_failed, source: name, error: "extraction was not committed to the ledger", ms: ms_since(started))
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
      def drive_agent(klass, tag, prompt = nil, max_turns: 20)
        started = clock
        emit(:"#{tag}_started")
        agent = klass.new(cwd: Config.sandbox_dir)
        text = block_given? ? yield(agent) : prompt
        return if text.nil?

        agent.prompt(text, max_turns: max_turns) { |type, payload| forward_event(tag, type, payload) }
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

      # What the Publisher renders. With nothing new to brief, its presence is what
      # lets the run stop after the inboxes.
      DASHBOARD = "dashboard.html"

      # Tool rounds the digest builder gets. A full build reads every extraction file
      # and writes every section, and spent all 20 it used to have on a 212-item
      # seed; an update reads one file and writes a few keys.
      SYNTHESIS_TURNS = {full: 30, update: 20}.freeze

      # Copy the agent's DECLARED outputs (`produces`) onto the run record. Nexo
      # reads each name through this workflow's sandbox — the workspace every agent
      # shares — and stores the bytes on the run, so a deliverable outlives the
      # workspace that held it, and a caller driving this workflow as a library gets
      # the artifacts back without knowing where on disk they were written. Never
      # fatal.
      def collect_declared(agent, tag)
        return unless agent

        collected = collect_artifacts(agent)
        emit(:artifacts_collected, stage: tag, names: collected.map { |a| a["name"] }) unless collected.empty?
      rescue => e
        emit(:artifact_skipped, stage: tag, error: e.message)
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

      def synthesis_prompt(produced, stamp, plan)
        files = produced.values.map { |f| "`#{f}`" }.join(", ")
        timestamp = "The run timestamp is #{stamp.iso8601} (display: #{stamp.strftime("%A, %-d %B %Y · %H:%M UTC")})."
        if plan == :full
          "This is a FULL build. The per-source extraction files in the workspace are: " \
            "#{files}. #{timestamp} Build the whole digest per the skill: write it to " \
            "`#{DigestFile::UPDATE}`, call commit_digest, then write `inbox-digest.md`."
        else
          "This is an UPDATE: `#{DigestFile::FILE}` holds the digest an earlier run saved. " \
            "#{timestamp} Update it per the skill: call new_items for the mail triaged " \
            "since, write only the top-level keys that change to `#{DigestFile::UPDATE}`, " \
            "call commit_digest, then rewrite `inbox-digest.md`. Work from new_items and " \
            "`#{DigestFile::FILE}` alone — do not re-read the extraction files."
        end
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
        # A gap means WEAKER isolation than the name suggests — an unfenced shell on
        # "local" — so it is worth an event rather than a shrug.
        gaps = agent.sandbox.hardening_gaps
        emit(:publisher_hardening_gaps, gaps: gaps) unless gaps.empty?

        skill = Agents::Publisher.skills.first
        staged = stage_skill_resources(skill, agent.sandbox)
        renderer = Config.dashboard_renderer(skill) { staged[:scripts]&.first }
        template = Config.dashboard_template(skill) { staged[:assets]&.first }
        unless renderer && template
          emit(:publisher_failed, error: "the #{skill} skill ships no #{renderer ? "asset" : "script"} to render with")
          return nil
        end

        "Render the dashboard per the #{skill} skill, with the shell tool. Its script " \
          "and template have been staged into your workspace, so you can read or glob " \
          "them if you need to. Run exactly:\n\n" \
          "  #{publisher_ruby} #{renderer.inspect} digest.json #{template.inspect} dashboard.html\n\n" \
          "Then confirm in one line. Do not hand-write the HTML."
      end

      # `[dashboard] ruby` pins a HOST interpreter — the answer to a narrowed sandbox
      # PATH. Inside a container that path does not exist; the image's own ruby is the
      # only one there, and choosing the image is how you choose it.
      def publisher_ruby = Config.dashboard_containerized? ? "ruby" : Config.dashboard_ruby

      # Copies every file the skill ships into the sandbox, preserving the
      # scripts//assets/ layout so the agent can glob `scripts/*` the way the skill's
      # own prose describes. Returns workspace-relative paths grouped by kind.
      #
      # Nexo::Skills.materialize does this through the SANDBOX's own #write.
      # Overwrites each run, which is what bounds tampering with a staged script to
      # a single turn. Never fatal.
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
