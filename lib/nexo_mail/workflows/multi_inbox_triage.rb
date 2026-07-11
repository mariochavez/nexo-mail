# frozen_string_literal: true

module NexoMail
  module Workflows
    # Triages Apple Mail (MCP), Gmail (IMAP) and HEY (CLI) with one agent per source.
    # Each source agent writes its digest fragment into the sandbox; a merge agent
    # then reads those fragments (handed to it in the prompt) and writes the unified
    # inbox-digest.md, which is recorded as the run's artifact.
    #
    # Bulletproof by design: a source whose binary is missing or whose credentials are
    # absent is SKIPPED up front (with a reason), and one that errors mid-run degrades
    # to a failed note — either way the run continues with whatever is available.
    class MultiInboxTriage < Nexo::Workflow
      # name => [agent class, fragment filename]
      SOURCES = {
        "Apple Mail" => [Agents::AppleMailSource, "apple-mail.md"],
        "Gmail"      => [Agents::GmailSource, "gmail.md"],
        "HEY"        => [Agents::HeySource, "hey.md"]
      }.freeze

      DIGEST_FILE = "inbox-digest.md"

      def call(_payload)
        FileUtils.mkdir_p(sandbox_dir)

        available, skipped = partition_sources
        skipped.each { |name, reason| emit(:source_skipped, source: name, reason: reason) }

        fragments = available.keys.zip(fan_out_sources(available)).to_h

        merged = fragments.empty? ? no_sources_digest(skipped) : merge(fragments)
        artifact(DIGEST_FILE, content: merged)
        {sources: fragments.keys, skipped: skipped, bytes: merged.length}
      end

      private

      def sandbox_dir = Config.sandbox_dir

      # Run the merge agent to unify the fragments. If it fails (e.g. the model is
      # down), the run must NOT die and lose the per-source work — fall back to the
      # concatenated fragments so a digest is always produced.
      def merge(fragments)
        emit(:merging, sources: fragments.keys)
        Agents::MergeDigests.new(cwd: sandbox_dir).prompt(merge_prompt(fragments), max_turns: 6) do |type, payload|
          forward_event("merge", type, payload)
        end
        digest_path = File.join(sandbox_dir, DIGEST_FILE)
        File.exist?(digest_path) ? File.read(digest_path) : fallback_digest(fragments)
      rescue => e
        emit(:merge_failed, error: e.message)
        fallback_digest(fragments)
      end

      def fallback_digest(fragments)
        "# Inbox Digest\n\n_(merge unavailable — showing per-source digests)_\n\n" +
          fragments.map { |name, frag| "## #{name}\n\n#{frag}" }.join("\n\n")
      end

      def no_sources_digest(skipped)
        "# Inbox Digest\n\n_No sources available._\n" +
          skipped.map { |name, reason| "- **#{name}** skipped: #{reason}" }.join("\n")
      end

      # Split SOURCES into the ones that can run now and the ones to skip (with a
      # reason), using each source's preflight availability check. This is what keeps
      # a missing binary or absent credentials from sinking the whole run.
      def partition_sources
        available = {}
        skipped = {}
        SOURCES.each do |name, (klass, file)|
          reason = safe_availability(klass)
          reason ? (skipped[name] = reason) : (available[name] = [klass, file])
        end
        [available, skipped]
      end

      # A broken availability check must never crash the run — treat a raising check
      # as "available" and let the per-source rescue handle any real failure at run time.
      def safe_availability(klass)
        klass.availability
      rescue => e
        emit(:availability_check_failed, source: klass.name, error: e.message)
        nil
      end

      # Triage the available sources concurrently: their LLM round-trips (the bulk of
      # the wall-clock) overlap inside one async reactor, bounded to the source count.
      # Results come back in submission order so the caller can zip them to their names.
      # Each source writes a distinct fragment file — no write contention. Falls back to
      # sequential when `async` is absent.
      def fan_out_sources(sources)
        return [] if sources.empty?

        Nexo.concurrent(max_in_flight: sources.size) do |c|
          sources.each { |name, (klass, file)| c.add { triage_source(name, klass, file) } }
        end
      rescue Nexo::MissingDependencyError => e
        emit(:async_unavailable, error: e.message)
        sources.map { |name, (klass, file)| triage_source(name, klass, file) }
      end

      # Runs one source agent, which writes its fragment into the sandbox; returns the
      # fragment text (read back from disk). A failing source degrades to a note.
      def triage_source(name, klass, file)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        emit(:source_started, source: name, file: file)
        agent = klass.new(cwd: sandbox_dir)
        agent.prompt(
          "Triage this inbox per the skill, then save the digest to the file `#{file}` in the workspace.",
          max_turns: 30
        ) { |type, payload| forward_event(name, type, payload) }

        path = File.join(sandbox_dir, file)
        fragment = File.exist?(path) ? File.read(path) : "### #{name}\n\n_No fragment written._"
        emit(:source_done, source: name, bytes: fragment.length, ms: ms_since(started))
        fragment
      rescue => e
        emit(:source_failed, source: name, error: e.message, ms: ms_since(started))
        "### #{name}\n\n_Triage failed: #{e.message}_"
      ensure
        agent&.close
      end

      def ms_since(t0)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      end

      # Mirror an agent event into the workflow log with a compact, source-tagged shape.
      def forward_event(source, type, payload)
        data =
          case type
          when :tool_call then {source: source, tool: payload.respond_to?(:name) ? payload.name : payload.to_s}
          when :tool_result then {source: source, result: payload.to_s[0, 200]}
          else {source: source, info: payload.to_s[0, 200]}
          end
        emit(:"agent_#{type}", **data)
      end

      def merge_prompt(fragments)
        sections = fragments.map { |name, frag| "### Source: #{name}\n\n#{frag}" }.join("\n\n---\n\n")
        "Merge these per-source triage digests into one unified digest and save it to " \
          "`#{DIGEST_FILE}`:\n\n#{sections}"
      end
    end
  end
end
