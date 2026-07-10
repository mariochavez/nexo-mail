# frozen_string_literal: true

# Lists the HEY Imbox postings as JSON via `hey box imbox --json`. Read-only: it
# only ever runs that one read subcommand.
class HeyImbox < RubyLLM::Tool
  description "List HEY Imbox postings (sender, subject) as JSON. Read-only."

  def execute
    CliReader.json("hey", "box", "imbox", "--json")
  end
end
