# frozen_string_literal: true

module NexoMail
  module Tools
    module GmailImap
      # Reads message bodies by UID — many at a time, decoded, in ONE IMAP session.
      #
      # Two changes from reading one uid per call, both load-bearing:
      #
      # 1. BATCHED. Every uid in the request shares one connection, so a run costs two
      #    IMAP sessions (list + read) instead of 1 + N. It also costs ONE model round
      #    trip instead of N, which is the larger saving — RubyLLM's tool_concurrency
      #    is off, so tool calls are strictly sequential.
      #
      # 2. DECODED. The old tool returned raw BODY[TEXT]: on a multipart message that
      #    is MIME boundaries and base64, so the 4000-character budget was spent on
      #    transport rather than prose. BodyPart picks the text part and Mime decodes
      #    it, which is also why the mojibake rule in CLAUDE.md holds here.
      class Read < RubyLLM::Tool
        description <<~DESC.strip
          Read Gmail message BODIES by UID — pass ALL the uids you need in ONE call (up
          to 25). Returns decoded plain text per uid (base64/quoted-printable decoded,
          HTML stripped, truncated). Read-only. Example: {"uids": [40182, 40190]}

          Only for messages the list snippet could not settle: a receipt whose exact
          total you must read, an invitation whose time you need, a genuinely ambiguous
          sender. Collect those uids first, then make one call.
        DESC

        params do
          array :uids, description: "UIDs from the list tool" do
            integer
          end
          integer :max_chars, description: "Max body characters per message (default 4000)", required: false
        end

        def execute(uids:, max_chars: nil)
          # Coerce defensively: the schema says integers, but a model can still send
          # ["40182"] or a bare 40182.
          wanted = Array(uids).flatten.map { |uid| uid.to_i }.reject(&:zero?).uniq
          return JSON.generate(messages: [], error: "no usable uids — pass the `uid` values from the list tool") if wanted.empty?

          cap = Config.gmail_read_max_uids
          skipped = wanted.drop(cap)
          wanted = wanted.first(cap)
          chars = (max_chars || Config.gmail_body_chars).to_i.clamp(200, 20_000)

          # with_inbox answers { error: } on a credential/network fault, in which case
          # there is no message list to annotate.
          result = GmailImap.with_inbox { |imap| read_all(imap, wanted, chars) }
          result[:skipped] = skipped if result.key?(:messages) && !skipped.empty?
          JSON.generate(result)
        end

        private

        def read_all(imap, uids, chars)
          rows = imap.uid_fetch(uids, %w[UID ENVELOPE BODYSTRUCTURE]).to_h do |d|
            [d.attr["UID"], d]
          end
          missing = uids - rows.keys
          messages = rows.transform_values { |d| meta(d) }
          fill_bodies(imap, rows, messages, chars)

          # `messages` is ALWAYS present, even empty — a reply carrying only errors
          # reads as a broken tool rather than as "none of those uids exist".
          errors = missing.map { |uid| {uid: uid, error: "message uid #{uid} not found"} }
          result = {messages: messages.values}
          result[:errors] = errors unless errors.empty?
          result
        end

        def meta(data)
          env = data.attr["ENVELOPE"]
          {
            uid: data.attr["UID"],
            from: GmailImap.format_address(env&.from&.first),
            subject: env&.subject,
            date: env&.date.to_s
          }
        end

        # Same grouped-section trick as the listing: one fetch per distinct body
        # section rather than one per message, all in the open session. Fetches the
        # FULL part (no partial range) and truncates after decoding, so the character
        # budget is spent on readable text.
        def fill_bodies(imap, rows, messages, chars)
          parts = rows.transform_values { |d| BodyPart.pick(d.attr["BODYSTRUCTURE"]) }

          parts.compact.group_by { |_uid, part| part.section }.each do |section, pairs|
            fetched = imap.uid_fetch(pairs.map(&:first), ["BODY.PEEK[#{section}]"])
            Array(fetched).each do |d|
              uid = d.attr["UID"]
              part = parts[uid]
              message = messages[uid]
              next unless part && message

              text = Mime.to_text(GmailImap.raw_body(d), encoding: part.encoding,
                charset: part.charset, subtype: part.subtype)
              message[:body] = text[0, chars]
              message[:truncated] = true if text.length > chars
            end
          rescue => e
            RubyLLM.logger.debug { "gmail body fetch failed for section #{section}: #{e.class}: #{e.message}" }
          end

          # Say so rather than omitting the key: a missing body is a fact the model
          # needs (attachment-only mail, or a part Gmail would not serve).
          messages.each_value { |m| m[:body] ||= "" }
        end
      end
    end
  end
end
