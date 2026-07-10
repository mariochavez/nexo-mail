# frozen_string_literal: true

# Inherits the shared triage config (model, :local sandbox + write, skill); it
# attaches no mail tools (source_tools defaults to []) and reads the per-source
# fragments handed to it in the prompt, writing ONE unified digest.
class MergeDigests < SourceAgent
  instructions <<~TXT
    You merge several per-source email triage digests into ONE unified digest.
    Pool the "Needs action" items across sources first, then the "FYI" items,
    tagging each line with its source, e.g. "[Gmail]". Apply the always-surface
    rules from the skill. Save the result to the file named in the prompt with the
    write tool, then confirm in one line.
  TXT
end
