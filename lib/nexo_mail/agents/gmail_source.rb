# frozen_string_literal: true

module NexoMail
  module Agents
    # Gmail — reached read-only over IMAP with an App Password (no gcloud/OAuth).
    class GmailSource < SourceAgent
      def self.source_tools = [Tools::GmailImap::List, Tools::GmailImap::Read]

      def self.prompt_key = "gmail"

      def self.availability
        if Config.gmail_address.to_s.empty? || Config.gmail_app_password.to_s.empty?
          "Gmail not configured — set [services.gmail] in config.toml or NEXO_MAIL_GMAIL_*"
        end
      end
    end
  end
end
