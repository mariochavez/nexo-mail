# frozen_string_literal: true

module NexoMail
  module Tools
    # ALTERNATE Gmail path (see GwsGmailUnread). Reads one Gmail message by id via
    # `gws gmail +read`. Read-only.
    class GwsGmailRead < RubyLLM::Tool
      description "Read one Gmail message by its id (headers + plain-text body) as JSON. Read-only."
      param :id, type: :string, required: true, desc: "The Gmail message id from a +triage listing"

      def execute(id:)
        CliReader.json("gws", "gmail", "+read", "--id", id.to_s, "--headers", "--format", "json")
      end
    end
  end
end
