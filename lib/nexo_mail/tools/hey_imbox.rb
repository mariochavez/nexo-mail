# frozen_string_literal: true

module NexoMail
  module Tools
    # Lists the HEY Imbox postings as JSON via `hey box imbox --json`. Read-only.
    class HeyImbox < RubyLLM::Tool
      description "List HEY Imbox postings (sender, subject) as JSON. Read-only."

      def execute
        CliReader.json("hey", "box", "imbox", "--json")
      end
    end
  end
end
