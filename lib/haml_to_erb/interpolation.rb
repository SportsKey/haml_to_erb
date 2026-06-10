# frozen_string_literal: true

module HamlToErb
  # Converts Ruby #{...} interpolation in plain (already-decoded) text to <%= ... %> ERB tags.
  # Handles nested braces correctly (e.g., #{hash[:key]}).
  # Preserves escaped interpolation \#{expr} as literal #{expr}.
  module Interpolation
    def self.convert(text)
      result = +""
      i = 0

      while i < text.length
        if text[i, 2] == '#{'
          # Count preceding backslashes to detect escaping
          num_backslashes = 0
          j = i - 1
          while j >= 0 && text[j] == "\\"
            num_backslashes += 1
            j -= 1
          end

          if num_backslashes.odd?
            # Escaped interpolation: output literal #{
            # Remove the escape backslash from result
            result.chop!
            result << '#{'
            i += 2
          else
            # Unescaped: convert to ERB
            finish = interpolation_end(text, i)
            result << "<%= #{text[(i + 2)...(finish - 1)]} %>"
            i = finish
          end
        else
          result << text[i]
          i += 1
        end
      end

      result
    end

    # Given +text+ and index +start+ pointing at the start of a "#{" sequence,
    # return the index just past its matching "}". Tracks brace depth and skips
    # over nested string literals. Raises ArgumentError if unterminated.
    # Also used by StringLiteralDecoder.
    def self.interpolation_end(text, start)
      depth = 1
      j = start + 2
      in_string = nil

      while j < text.length && depth.positive?
        char = text[j]
        if in_string
          if char == in_string
            num_backslashes = 0
            k = j - 1
            while k >= 0 && text[k] == "\\"
              num_backslashes += 1
              k -= 1
            end
            in_string = nil unless num_backslashes.odd?
          end
        elsif [ '"', "'" ].include?(char)
          in_string = char
        elsif char == "{"
          depth += 1
        elsif char == "}"
          depth -= 1
        end
        j += 1
      end

      raise ArgumentError, "Unclosed interpolation starting at position #{start} in: #{text}" if depth.positive?

      j
    end
  end
end
