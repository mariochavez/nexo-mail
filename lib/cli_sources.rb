# frozen_string_literal: true

require "open3"
require "json"
require "ruby_llm"

# Thin, read-only wrappers around the Gmail (`gws`) and HEY (`hey`) command-line
# tools, exposed to an agent as RubyLLM tools. This is the "wrapped read-only
# tool" integration: each tool shells out to ONE hardcoded READ subcommand — the
# model never gets a general shell, so read-only holds by construction.
module CliSources
  # Runs a CLI as an ARGV ARRAY via Open3 (never a shell string) so nothing the
  # model supplies can be interpreted as shell syntax — no injection surface.
  # Returns parsed JSON on success, { raw: } if the output isn't JSON, or
  # { error: } on a non-zero exit / missing binary (recoverable for the model).
  module CliReader
    module_function

    def json(*argv)
      out, err, status = Open3.capture3(*argv)
      unless status.success?
        return {error: "#{argv.first} exited #{status.exitstatus}: #{err.strip[0, 300]}"}
      end

      begin
        JSON.parse(out)
      rescue JSON::ParserError
        {raw: out.strip[0, 4000]}
      end
    rescue Errno::ENOENT
      {error: "`#{argv.first}` not found on PATH — is it installed and authenticated?"}
    end
  end

  # --- Gmail via the Google Workspace CLI (`gws`) -----------------------------
  # NOTE: these are the ALTERNATE Gmail path. The DEFAULT is IMAP (GmailImap in
  # lib/gmail_imap.rb); GmailSource uses that. Swap these in only if you want
  # Gmail's native API — see the comment on GmailSource in lib/multi_inbox.rb.
  #
  # `gws gmail +triage` returns an inbox summary (sender, subject, date) as JSON.
  # Read-only: only ever the +triage read subcommand. Optional Gmail search query
  # (default is:unread) and a cap on messages.
  class GmailUnread < RubyLLM::Tool
    description "List Gmail messages matching a query (default is:unread) as JSON: id, sender, subject, date. Read-only."
    param :query, type: :string, required: false, desc: "Gmail search query, e.g. 'is:unread' or 'newer_than:1d'"
    param :max, type: :integer, required: false, desc: "Max messages (default 20)"

    def execute(query: "is:unread", max: 20)
      CliSources::CliReader.json(
        "gws", "gmail", "+triage", "--format", "json", "--query", query.to_s, "--max", max.to_i.to_s
      )
    end
  end

  # `gws gmail +read --id <ID>` extracts one message's body/headers. Read-only.
  class GmailRead < RubyLLM::Tool
    description "Read one Gmail message by its id (headers + plain-text body) as JSON. Read-only."
    param :id, type: :string, required: true, desc: "The Gmail message id from a +triage listing"

    def execute(id:)
      CliSources::CliReader.json("gws", "gmail", "+read", "--id", id.to_s, "--headers", "--format", "json")
    end
  end

  # --- HEY via the Basecamp CLI (`hey`) ---------------------------------------
  # `hey box imbox --json` lists the postings in the Imbox; `hey threads <id>
  # --json` reads one full thread. Both are read-only.
  class HeyImbox < RubyLLM::Tool
    description "List HEY Imbox postings (sender, subject) as JSON. Read-only."

    def execute
      CliSources::CliReader.json("hey", "box", "imbox", "--json")
    end
  end

  class HeyThread < RubyLLM::Tool
    description "Read one HEY email thread by its numeric id, as JSON. Read-only."
    param :id, type: :integer, required: true, desc: "The thread id from the Imbox listing"

    def execute(id:)
      CliSources::CliReader.json("hey", "threads", id.to_i.to_s, "--json")
    end
  end
end
