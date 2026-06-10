# frozen_string_literal: true

require_relative "interpolation"

module HamlToErb
  # Decodes a Ruby double-quoted string literal (as produced by String#dump) into ERB.
  # Restores \uXXXX / \u{...} / \n / \t and other escapes back to their original
  # characters, and converts live #{...} interpolation to <%= ... %> output tags.
  module StringLiteralDecoder
    # Single-character Ruby escape sequences. An unknown \c decodes to c itself,
    # matching Ruby's behaviour.
    SINGLE_CHAR_ESCAPES = {
      "n" => "\n", "t" => "\t", "r" => "\r", "s" => " ",
      "a" => "\a", "b" => "\b", "e" => "\e", "f" => "\f",
      "v" => "\v", "0" => "\0", "\\" => "\\", '"' => '"',
      "'" => "'", "#" => "#"
    }.freeze

    # Decode +literal+ (including surrounding double quotes) to ERB.
    def self.decode(literal)
      inner = literal[1...-1]
      result = +""
      i = 0

      while i < inner.length
        if inner[i, 2] == '#{'
          # Live interpolation: emit ERB, copying the expression verbatim so
          # its Ruby source (which Haml did not dump-escape) is preserved.
          finish = Interpolation.interpolation_end(inner, i)
          result << "<%= #{inner[(i + 2)...(finish - 1)]} %>"
          i = finish
        elsif inner[i] == "\\"
          # Escape sequence in the dumped literal text. Decoding \# yields a
          # literal "#", so an originally-escaped \#{...} becomes literal text
          # rather than being mistaken for interpolation above.
          decoded, consumed = decode_escape(inner, i)
          result << decoded
          i += consumed
        else
          result << inner[i]
          i += 1
        end
      end

      result
    end

    # Decode the escape sequence in +text+ beginning at index +start+ (where
    # text[start] is a backslash). Returns [decoded_string, characters_consumed].
    def self.decode_escape(text, start)
      c = text[start + 1]

      case c
      when nil
        # Trailing backslash with nothing to escape; keep it literal.
        [ "\\", 1 ]
      when "u"
        decode_unicode_escape(text, start)
      when "x"
        # \xHH hex byte (1-2 digits). Rarely produced by String#dump for valid
        # UTF-8 templates, but decoded for completeness.
        hex = text[(start + 2), 2][/\A\h{1,2}/]
        return [ "\\x", 2 ] if hex.nil?

        [ hex.to_i(16).chr, 2 + hex.length ]
      else
        [ SINGLE_CHAR_ESCAPES.fetch(c, c), 2 ]
      end
    end

    # Decode a \uXXXX (4 hex digits) or \u{XXXX ...} (one or more space-separated
    # codepoints) escape starting at index +start+ in +text+.
    def self.decode_unicode_escape(text, start)
      if text[start + 2] == "{"
        close = text.index("}", start + 3)
        raise ArgumentError, "Unterminated \\u{...} escape in: #{text}" if close.nil?

        codepoints = text[(start + 3)...close].split(/\s+/).reject(&:empty?).map { |h| h.to_i(16) }
        [ codepoints.pack("U*"), close - start + 1 ]
      else
        hex = text[(start + 2), 4]
        [ [ hex.to_i(16) ].pack("U"), 6 ]
      end
    end

    private_class_method :decode_escape, :decode_unicode_escape
  end
end
