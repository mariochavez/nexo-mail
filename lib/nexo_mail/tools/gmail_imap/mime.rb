# frozen_string_literal: true

module NexoMail
  module Tools
    module GmailImap
      # Turns what IMAP actually hands back into text a model can classify from.
      #
      # This is transport decoding, not interpretation: BODY[...] arrives
      # base64- or quoted-printable-encoded, in whatever charset the sender chose,
      # frequently wrapped in HTML. Before this existed the triage agent received
      # raw MIME inside its 4000-character body budget and was expected to read
      # amounts out of it. The model cannot see the wire — only the tool can.
      #
      # Also the ground floor of the mojibake rule in CLAUDE.md: if dashboard text
      # ever renders as "MÃ©xico", the fault is a mail-reading tool's decoding, and
      # this is that decoding.
      module Mime
        # Entities worth resolving in mail HTML. Numeric refs are handled separately.
        ENTITIES = {
          "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => '"',
          "&apos;" => "'", "&#39;" => "'", "&nbsp;" => " ", "&mdash;" => "—",
          "&ndash;" => "–", "&hellip;" => "…", "&rsquo;" => "’", "&lsquo;" => "‘",
          "&ldquo;" => "“", "&rdquo;" => "”", "&trade;" => "™", "&copy;" => "©",
          "&reg;" => "®", "&euro;" => "€", "&pound;" => "£", "&middot;" => "·"
        }.freeze

        BLOCK_TAGS = %r{</?(?:br|p|div|tr|li|h[1-6]|table|blockquote)\b[^>]*>}i
        DROP_BLOCKS = %r{<(script|style|head)\b[^>]*>.*?</\1>}mi

        module_function

        # Decodes one body part. +raw+ may be a PARTIAL fetch, so both decoders are
        # written to tolerate being cut mid-symbol rather than raising.
        def decode(raw, encoding: nil, charset: nil)
          text =
            case encoding.to_s.upcase
            when "BASE64" then decode_base64(raw)
            when "QUOTED-PRINTABLE" then decode_quoted_printable(raw)
            else raw.to_s
            end
          to_utf8(text, charset)
        end

        # A partial fetch almost never lands on a 4-byte boundary, and a trailing
        # fragment decodes to garbage — so drop it before unpacking.
        def decode_base64(raw)
          data = raw.to_s.gsub(/\s+/, "")
          data = data[0, data.length - (data.length % 4)].to_s
          data.unpack1("m") || ""
        rescue ArgumentError
          raw.to_s
        end

        # Same idea: a truncated "=A" or trailing soft-break "=" would otherwise
        # decode to a stray byte.
        def decode_quoted_printable(raw)
          raw.to_s.sub(/=[0-9A-Fa-f]?\z/, "").unpack1("M") || ""
        rescue ArgumentError
          raw.to_s
        end

        # Force the declared charset, then transcode to UTF-8 replacing anything
        # invalid. Falls back to ISO-8859-1 (which accepts every byte) when the
        # declared charset doesn't fit the bytes, so this never raises and never
        # returns an invalidly-encoded String.
        def to_utf8(text, charset)
          str = text.to_s.dup
          begin
            str.force_encoding(charset.to_s.empty? ? "UTF-8" : charset)
          rescue ArgumentError
            str.force_encoding("UTF-8")
          end
          str.force_encoding("ISO-8859-1") unless str.valid_encoding?
          str.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        end

        # Best-effort HTML to text. Not a parser and not trying to be — the goal is
        # that "Total: $12.34" survives and the tags don't.
        def strip_html(html)
          text = html.to_s.gsub(DROP_BLOCKS, " ")
          text = text.gsub(BLOCK_TAGS, "\n").gsub(/<[^>]*>/m, " ")
          unescape(text)
        end

        def unescape(text)
          text.to_s
            .gsub(/&[a-zA-Z]+;|&#\d+;/) do |entity|
              ENTITIES[entity.downcase] ||
                (entity.start_with?("&#") ? [entity[2..-2].to_i].pack("U") : entity)
            end
        end

        # Collapse the whitespace mail is padded with, so the character budget buys
        # content instead of indentation.
        def squeeze(text)
          text.to_s
            .gsub(/\r\n?/, "\n")
            .gsub(/[ \t ]+/, " ")
            .gsub(/ ?\n ?/, "\n")
            .gsub(/\n{3,}/, "\n\n")
            .strip
        end

        # decode -> strip_html when it's HTML -> squeeze. The one call the tools make.
        def to_text(raw, encoding: nil, charset: nil, subtype: nil)
          text = decode(raw, encoding: encoding, charset: charset)
          text = strip_html(text) if subtype.to_s.casecmp?("html")
          squeeze(text)
        end
      end
    end
  end
end
