# frozen_string_literal: true

module NexoMail
  # The catalog of email sources the workflow triages. Each entry is a descriptor
  # exposing a uniform interface — #name, #file, #available?, #build(cwd:) — so the
  # workflow stays orchestration-only: it never names a source class, it just walks
  # this table.
  #
  # Tool-based sources (Gmail, HEY) are pure data: a Descriptor carries the tools
  # that reach the inbox, the prompt-fragment key, and an availability lambda, and
  # builds a shared Agents::EmailSource from itself. Adding such a service means
  # adding a Descriptor here — no new class. Apple Mail reaches its inbox through
  # Nexo's class-level `mcp` macro, which can't be expressed per-instance, so it
  # keeps its own Agents::AppleMailSource subclass; AppleDescriptor is the thin
  # duck-typed adapter that lets the workflow treat it like any other source.
  module Sources
    Descriptor = Struct.new(:name, :file, :prompt_key, :tools, :availability) do
      def available? = availability.call
      def build(cwd:) = Agents::EmailSource.new(descriptor: self, cwd: cwd)
    end

    AppleDescriptor = Struct.new(:name, :file) do
      def available? = Agents::AppleMailSource.availability
      def build(cwd:) = Agents::AppleMailSource.new(cwd: cwd)
    end

    # Built fresh on each call (not a frozen constant) because the availability
    # lambdas read Config, which is only loaded in CLI.run — after boot.
    def self.all
      [
        AppleDescriptor.new(name: "Apple Mail", file: "apple-mail.json"),
        Descriptor.new(
          name: "Gmail",
          file: "gmail.json",
          prompt_key: "gmail",
          tools: [Tools::GmailImap::List, Tools::GmailImap::Read],
          availability: lambda {
            if Config.gmail_address.to_s.empty? || Config.gmail_app_password.to_s.empty?
              "Gmail not configured — set [services.gmail] in config.toml or NEXO_MAIL_GMAIL_*"
            end
          }
        ),
        Descriptor.new(
          name: "HEY",
          file: "hey.json",
          prompt_key: "hey",
          tools: [Tools::HeyBox, Tools::HeyThread],
          # do...end (not braces) — a rescue clause is only legal in a do-block.
          availability: lambda do
            next "hey not found on PATH" unless Agents::EmailSource.command?("hey")

            data = Tools::Hey.run("auth", "status", "--json")
            data = data.is_a?(Hash) ? (data["data"] || {}) : {}
            next "hey not authenticated (run `hey auth login`)" unless data["authenticated"]
            next "hey session expired (run `hey auth login`)" if data["expired"]

            nil
          rescue
            nil # if the check itself errors, let the run attempt and fail gracefully
          end
        )
      ]
    end
  end
end
