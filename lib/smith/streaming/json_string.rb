# frozen_string_literal: true

module Smith
  module Streaming
    # A JSON string's characters after its opening quote, given one at a
    # time and unescaped as they come (JsonField). A UTF-16 surrogate pair
    # (two escapes) is one character; half of one alone, or a `\u` escape
    # that is not four hex digits, is the replacement character.
    class JsonString
      ESCAPES = { '"' => '"', "\\" => "\\", "/" => "/", "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r",
                  "t" => "\t" }.freeze
      REPLACEMENT = "�"
      private_constant :ESCAPES, :REPLACEMENT

      attr_reader :text

      def initialize
        @text = String.new(encoding: Encoding::UTF_8)
        @escape = false
        @unicode = @high = nil
        @closed = false
      end

      def closed? = @closed

      def add(char)
        return unicode_digit(char) if @unicode
        return escaped(char) if @escape

        case char
        when "\\" then @escape = true
        when '"' then close
        else append(char)
        end
      end

      private

      def escaped(char)
        @escape = false
        char == "u" ? @unicode = +"" : append(ESCAPES.fetch(char, char))
      end

      def unicode_digit(char)
        @unicode << char
        return if @unicode.length < 4

        digits = @unicode
        @unicode = nil
        digits.match?(/\A\h{4}\z/) ? append_code(digits.hex) : append(REPLACEMENT)
      end

      def append_code(code)
        high = @high
        @high = nil
        return @text << (0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)).chr(Encoding::UTF_8) if
          high && code.between?(0xDC00, 0xDFFF)

        @text << REPLACEMENT if high
        if code.between?(0xD800, 0xDBFF) then @high = code
        else @text << (code.between?(0xDC00, 0xDFFF) ? REPLACEMENT : code.chr(Encoding::UTF_8))
        end
      end

      def append(text)
        @text << REPLACEMENT if @high
        @high = nil
        @text << text
      end

      def close
        append("")
        @closed = true
      end
    end
  end
end
