# frozen_string_literal: true

module NexoMail
  module Agents
    # Builds the digest. Attaches NO mail tools — it works from what the source
    # agents extracted and keeps ONE picture of it: deduped items, rolled-up money,
    # ordered schedule, narrative stories, per-person detail and per-topic radar.
    #
    # Two ways to run, chosen by the workflow (DigestFile.plan): a FULL build reads
    # every extraction file; an UPDATE is handed only the items no digest holds yet
    # (Tools::NewItems) and rewrites the sections they touch. Either way it writes
    # `digest.update.json` and calls Tools::CommitDigest, which replaces just those
    # top-level keys in `digest.json` — plus `inbox-digest.md`, the terminal digest.
    class Synthesize < Base
      skills "inbox-synthesis", "financial-summary", "interest-radar"

      def self.prompt_key = "synthesize"

      # digest.json is the canonical artifact of the whole pipeline — everything
      # downstream (dashboard, snapshot, terminal digest) is a view of it. Declaring
      # both here means the workflow records them on the run itself, so they survive
      # the workspace (nexo_ai >= 0.9).
      produces "digest.json", "inbox-digest.md"

      # Money is computed, not transcribed: MoneyReport reads every payment on record,
      # sums it per currency and stages the finished `finance` section for
      # CommitDigest. The model used to add the numbers (USD 289.00 against its own
      # list summing to 269.00), then to re-type them into a calculator; now it does
      # neither. NewItems hands over what no digest holds yet.
      tools Tools::MoneyReport, Tools::NewItems

      # Replaces sections of digest.json and marks the items as digested. It changes
      # files on the host, so it is declared :write and gated like Nexo's own write.
      tools Tools::CommitDigest, capability: :write

      instructions <<~TXT
        You keep the digest, following the inbox-synthesis, financial-summary and
        interest-radar skills. The prompt says which kind of run this is. On a FULL
        build, read the extraction files it names and build the whole digest. On an
        UPDATE, call new_items for the mail triaged since the digest was saved, read
        `digest.json`, and change only what that mail touches. Either way: merge and
        de-duplicate, get the money picture from money_report (it saves `finance`
        itself — never write that key), order the
        schedule, and narrate stories, people and topic briefings. You never write
        `digest.json` yourself: write the top-level keys you built or changed to
        `digest.update.json` (exactly the schema in the skill) and call commit_digest,
        which saves them. Then write `inbox-digest.md` (a short terminal digest) and
        confirm in one line. Use the run timestamp the prompt gives you. You do not
        read mail; you only work from the tools and the workspace files.
      TXT
    end
  end
end
