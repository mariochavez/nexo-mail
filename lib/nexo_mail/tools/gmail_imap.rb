# frozen_string_literal: true

module NexoMail
  module Tools
    # Read-only Gmail access over IMAP using a Gmail App Password — no gcloud, no
    # OAuth. Credentials come from Config (config.toml [services.gmail] or the
    # NEXO_MAIL_GMAIL_* env vars). This module holds the shared connection helper;
    # the tools live in gmail_imap/list.rb and gmail_imap/read.rb.
    #
    # The mailbox is opened with EXAMINE (read-only), so the tools cannot mark,
    # move, or modify any message — read-only is guaranteed by the IMAP state.
    module GmailImap
      HOST = "imap.gmail.com"

      module_function

      # Connects, logs in, opens INBOX read-only, yields the imap handle, and always
      # tears the connection down. Returns the block's value, or an { error: } hash
      # (recoverable) on a missing credential / login / network fault.
      def with_inbox
        address  = Config.gmail_address.to_s
        password = Config.gmail_app_password.to_s.gsub(/\s+/, "")
        if address.empty? || password.empty?
          return {error: "Gmail is not configured — set [services.gmail] in config.toml or NEXO_MAIL_GMAIL_*"}
        end

        imap = Net::IMAP.new(HOST, ssl: true)
        begin
          imap.login(address, password)
          imap.examine("INBOX") # READ-ONLY select — cannot set \Seen, move, or delete
          yield imap
        ensure
          imap.logout rescue nil
          imap.disconnect rescue nil
        end
      rescue Net::IMAP::NoResponseError => e
        {error: "Gmail IMAP login failed: #{e.message} — check the App Password and that IMAP is enabled"}
      rescue => e
        {error: "Gmail IMAP error: #{e.class}: #{e.message}"}
      end

      # Format an IMAP ENVELOPE address struct as "Name <mailbox@host>".
      def format_address(addr)
        return nil unless addr

        email = [addr.mailbox, addr.host].compact.join("@")
        addr.name ? "#{addr.name} <#{email}>" : email
      end
    end
  end
end
