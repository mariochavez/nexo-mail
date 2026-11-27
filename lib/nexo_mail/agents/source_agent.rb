# frozen_string_literal: true

module NexoMail
  module Agents
    # Shared base for the per-source triage agents. They're identical except for
    # HOW each reaches its inbox (which tools it attaches): the extraction skills
    # and the triage instructions live here. Mail access stays read-only; the one
    # thing a source agent writes is its extraction file in the workspace.
    class SourceAgent < Base
      skills :email_triage, :financial_summary, :interest_radar

      # The one thing that advances the inbox's ledger. It changes files on the host
      # (the ledger, and the extraction file in the workspace), so it is declared
      # :write and gated like Nexo's own write tool.
      tools Tools::CommitExtraction, capability: :write

      instructions <<~TXT
        You triage ONE email inbox and EXTRACT it into structured JSON, following the
        attached skills: read the mail that is NEW since the last run, classify each
        message into action/fyi/noise, and pull the entities that matter — payments &
        charges (financial_summary), meetings, people, and newsletter topics
        (interest_radar). The listing tools only show mail no earlier run has triaged;
        what earlier runs extracted is already on record. Write a single JSON array of
        the NEW item objects to the file the prompt names, with the write tool — no
        prose in the file, just the array, and `[]` when nothing new arrived — then
        call commit_extraction ONCE to merge it into the inbox's extraction file, and
        confirm in one line. Work with the mail-reading tools you were given plus the
        write tool. Read-only: never send, delete, or modify mail.
      TXT
    end
  end
end
