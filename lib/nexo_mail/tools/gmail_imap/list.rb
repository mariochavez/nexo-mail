# frozen_string_literal: true

module NexoMail
  module Tools
    module GmailImap
      # Lists recent INBOX messages WITH a plain-text snippet, in one IMAP session.
      #
      # The snippet is the whole point. Without it the model had only sender/subject/
      # date to classify from, so anything ambiguous — and every receipt whose amount
      # it needed — forced a separate read call, each of which was its own model round
      # trip AND its own TCP+TLS+LOGIN. With it, one call usually settles the inbox.
      #
      # Cost of the snippet: BODYSTRUCTURE rides along in the batched envelope fetch
      # for free, then messages are GROUPED BY SECTION so a whole inbox needs only a
      # couple of extra partial fetches — not one per message — all inside the single
      # already-open session.
      class List < RubyLLM::Tool
        description <<~DESC.strip
          List recent Gmail INBOX messages as JSON — uid, from, subject, date, unread,
          and a plain-text `snippet` of the body. Read-only.

          Pass `since` (an ISO date) to bound how far back it reaches — you decide
          that; this tool does not know what today is.

          ONE call returns everything you need to classify the whole inbox. Classify
          from the snippet. Do NOT call the read tool for a message the snippet already
          settles — reach for it only when you must read an exact amount or time the
          snippet cut off, and then batch every such uid into a single read call.
        DESC

        param :only_unread, type: :boolean, required: false, desc: "Only unread messages (default true)"
        param :limit, type: :integer, required: false, desc: "Max messages, newest first (default 40)"
        param :since, type: :string, required: false, desc: "Only messages on/after this ISO date"
        param :since_days, type: :integer, required: false, desc: "Only messages newer than N days (alternative to since)"
        param :snippet_chars, type: :integer, required: false, desc: "Snippet length per message; 0 disables snippets (default 400)"

        def execute(only_unread: true, limit: nil, since: nil, since_days: nil, snippet_chars: nil)
          max = (limit || Config.gmail_list_limit).to_i.clamp(1, 200)
          # No date policy here: the agent says how far back to reach. `since` (an
          # ISO date) wins over `since_days` when both are given.
          since = since_date(since, since_days)
          chars = (snippet_chars || Config.gmail_snippet_chars).to_i.clamp(0, 2_000)

          result = GmailImap.with_inbox do |imap|
            uids = imap.uid_search(criteria(only_unread, since)).last(max)
            next {messages: [], count: 0} if uids.empty?

            rows = envelopes(imap, uids)
            attach_snippets(imap, rows, chars) if chars.positive?
            {messages: rows.values.reverse, count: rows.size} # newest first
          end
          JSON.generate(result)
        end

        private

        # Whichever the agent gave us, or nil for no date bound at all.
        def since_date(since, since_days)
          text = since.to_s.strip
          return Date.parse(text) unless text.empty?
          return Time.now.utc.to_date - since_days.to_i if since_days

          nil
        rescue ArgumentError
          nil
        end

        def criteria(only_unread, since)
          criteria = []
          criteria << "UNSEEN" if only_unread
          criteria += ["SINCE", since.strftime("%d-%b-%Y")] if since
          criteria.empty? ? ["ALL"] : criteria
        end

        # One UID FETCH for the metadata of every message. BODYSTRUCTURE comes along
        # so #attach_snippets knows which section to ask for without a second round
        # trip per message. Returns { uid => row }, ascending, so the snippet pass can
        # find rows by uid.
        def envelopes(imap, uids)
          imap.uid_fetch(uids, %w[UID ENVELOPE INTERNALDATE FLAGS BODYSTRUCTURE]).to_h do |d|
            env = d.attr["ENVELOPE"]
            uid = d.attr["UID"]
            [uid, {
              uid: uid,
              from: GmailImap.format_address(env&.from&.first),
              subject: env&.subject,
              date: (env&.date || d.attr["INTERNALDATE"]).to_s,
              unread: !Array(d.attr["FLAGS"]).include?(:Seen),
              structure: d.attr["BODYSTRUCTURE"]
            }]
          end
        end

        # Fetches snippets for every message in 1-3 extra commands: messages sharing a
        # body section ("TEXT", "1", "1.1" — in practice a handful of distinct values)
        # are fetched together with a PARTIAL fetch, so only the first few hundred
        # bytes of each body cross the wire.
        #
        # Each group is rescued independently: a section Gmail refuses leaves those
        # rows without a snippet rather than sinking the whole listing.
        def attach_snippets(imap, rows, chars)
          octets = (chars * 4).clamp(512, 8_192)
          parts = rows.transform_values { |row| BodyPart.pick(row.delete(:structure)) }

          parts.compact.group_by { |_uid, part| part.section }.each do |section, pairs|
            uids = pairs.map(&:first)
            begin
              fetched = imap.uid_fetch(uids, ["BODY.PEEK[#{section}]<0.#{octets}>"])
              Array(fetched).each do |d|
                row = rows[d.attr["UID"]]
                part = parts[d.attr["UID"]]
                next unless row && part

                text = Mime.to_text(GmailImap.raw_body(d), encoding: part.encoding,
                  charset: part.charset, subtype: part.subtype)
                row[:snippet] = text[0, chars] unless text.empty?
              end
            rescue => e
              RubyLLM.logger.debug { "gmail snippet fetch failed for section #{section}: #{e.class}: #{e.message}" }
            end
          end
        ensure
          rows.each_value { |row| row.delete(:structure) }
        end
      end
    end
  end
end
