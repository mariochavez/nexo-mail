# frozen_string_literal: true

module NexoMail
  module Agents
    # Shared base for the per-source triage agents. They're identical except for
    # HOW each reaches its inbox (which tools it attaches): the extraction skills
    # and the triage instructions live here. Mail access stays read-only; the one
    # thing a source agent writes is its extraction file in the workspace.
    class SourceAgent < Base
      skills :email_triage, :financial_summary, :interest_radar

      instructions <<~TXT
        You triage ONE email inbox and EXTRACT it into structured JSON, following the
        attached skills: read recent messages, classify each into action/fyi/noise,
        and pull the entities that matter — payments & charges (financial_summary),
        meetings, people, and newsletter topics (interest_radar). When the prompt
        names a file, write a single JSON array of item objects to it with the write
        tool, then confirm in one line. No prose in the file — just the array. Work
        with the mail-reading tools you were given plus the write tool. Read-only:
        never send, delete, or modify mail.
      TXT
    end
  end
end
