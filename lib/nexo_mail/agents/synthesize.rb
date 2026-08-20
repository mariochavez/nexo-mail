# frozen_string_literal: true

module NexoMail
  module Agents
    # Builds the digest. Inherits the shared triage config (model, :local sandbox +
    # read/write) but attaches NO mail tools — it reads the per-source extraction
    # files each source agent wrote into the workspace and merges them into ONE
    # picture: deduped items, rolled-up money, ordered schedule, narrative stories,
    # per-person detail and per-topic radar. It writes two files: `digest.json`
    # (canonical data) and `inbox-digest.md` (the terminal digest).
    #
    # It swaps the extraction skills for the synthesis ones — its guidance is about
    # connecting, rolling up, and narrating, not reading inboxes.
    class Synthesize < SourceAgent
      # Reset the skills inherited from SourceAgent's extraction set — the synthesis
      # agent builds the digest, it doesn't read inboxes. The `skills` macro only
      # accumulates, so override the inherited class ivar directly.
      @skills = %i[inbox_synthesis financial_summary interest_radar]

      def self.prompt_key = "synthesize"

      # The digest is where money arithmetic happens, and where it was measurably
      # wrong: by_currency reported USD 289.00 against its own list summing to 269.00
      # (and the true extracted figure was 1218.00). SumPayments does the addition and
      # hands back the list and the totals together so they cannot drift apart.
      def self.source_tools = [Tools::SumPayments]

      instructions <<~TXT
        You build the digest from the per-source extraction files already written to
        the workspace. Following the inbox_synthesis, financial_summary and
        interest_radar skills: read the source JSON files the prompt names, merge and
        de-duplicate the items, roll up the money per currency, order the schedule,
        and narrate stories, people and topic briefings. Write TWO files with the
        write tool — `digest.json` (the canonical data, exactly the schema in the
        skill) and `inbox-digest.md` (a short terminal digest) — using the run
        timestamp the prompt gives you. Then confirm in one line. You do not read
        mail; you only read the workspace files and write the two outputs.
      TXT
    end
  end
end
