# frozen_string_literal: true

# Reads one HEY thread by id as JSON via `hey threads <id> --json`. Read-only.
class HeyThread < RubyLLM::Tool
  description "Read one HEY email thread by its numeric id, as JSON. Read-only."
  param :id, type: :integer, required: true, desc: "The thread id from the Imbox listing"

  def execute(id:)
    CliReader.json("hey", "threads", id.to_i.to_s, "--json")
  end
end
