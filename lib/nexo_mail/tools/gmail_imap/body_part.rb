# frozen_string_literal: true

module NexoMail
  module Tools
    module GmailImap
      # Picks the ONE body section worth fetching out of a message's BODYSTRUCTURE.
      #
      # Why bother instead of just fetching BODY[TEXT]: on a typical multipart/
      # alternative marketing mail, BODY[TEXT] is the whole MIME payload — boundary
      # markers, headers, and a base64 HTML part — so the first few thousand
      # characters contain almost no readable text, and the transfer encoding is
      # per-part so it can't be decoded from the outside. Selecting the text/plain
      # part (or the HTML one, to be stripped) gives real prose in the same budget.
      #
      # BODYSTRUCTURE comes back in the SAME batched UID FETCH as the envelopes, so
      # this costs no extra round trip; only the follow-up part fetch does.
      module BodyPart
        Part = Struct.new(:section, :encoding, :charset, :subtype)

        # A non-multipart message has no numbered parts; "TEXT" is the whole body and
        # is also what we fall back to whenever the structure is unusable.
        WHOLE = Part.new(section: "TEXT", encoding: nil, charset: nil, subtype: nil)

        module_function

        # Returns the Part to fetch, or nil when the message carries no text at all
        # (attachment-only). Never raises: an unrecognised structure degrades to
        # WHOLE, which is exactly the old behaviour.
        def pick(structure)
          # Anything we do not recognise as a BODYSTRUCTURE degrades to the whole
          # body — the old behaviour — rather than to "no text", which would
          # silently drop the snippet.
          return WHOLE unless structure.respond_to?(:media_type) || multipart?(structure)

          if multipart?(structure)
            candidates = flatten(structure)
            plain = candidates.find { |p| p.subtype.to_s.casecmp?("plain") }
            plain || candidates.find { |p| p.subtype.to_s.casecmp?("html") }
          elsif text?(structure)
            part(structure, "TEXT")
          else
            nil # a bare attachment: no body worth reading
          end
        rescue
          WHOLE
        end

        # Depth-first walk numbering sections the way IMAP does: "1", "2", "2.1", …
        # message/rfc822 nesting is NOT descended into — its part numbering differs
        # between servers, and guessing a wrong section silently returns nothing.
        def flatten(structure, prefix = nil)
          Array(structure.parts).flat_map.with_index(1) do |child, i|
            section = [prefix, i].compact.join(".")
            if multipart?(child)
              flatten(child, section)
            elsif text?(child)
              [part(child, section)]
            else
              []
            end
          end
        end

        def part(structure, section)
          Part.new(
            section: section,
            encoding: structure.encoding,
            charset: charset(structure),
            subtype: structure.subtype
          )
        end

        def charset(structure)
          params = structure.param
          return nil unless params.respond_to?(:[])

          params["CHARSET"] || params["charset"]
        end

        def multipart?(structure)
          structure.respond_to?(:multipart?) ? structure.multipart? : false
        end

        # text/plain and text/html only. message/rfc822 reports media_type "MESSAGE"
        # and is skipped for the reason above.
        def text?(structure)
          structure.respond_to?(:media_type) && structure.media_type.to_s.casecmp?("text")
        end
      end
    end
  end
end
