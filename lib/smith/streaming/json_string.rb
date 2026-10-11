# frozen_string_literal: true

module Smith
  module Streaming
    # A JSON string's characters after its opening quote, given one at a
    # time and unescaped as they come (JsonField). A UTF-16 surrogate pair
    # (two escapes) is one character; half of one alone, or a `\u` escape
    # that is not four hex digits, is the replacement character. With a
    # `limit`, text past that many characters is dropped and the string is
    # `overflowed?`.
    class JsonString
      ESCAPES = { '"' => '"', "\\" => "\\", "/" => "/", "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r",
                  "t" => "\t" }.freeze
      REPLACEMENT = "\uFFFD"
      private_constant :ESCAPES, :REPLACEMENT

      attr_reader :text

      def initialize(limit: nil)
        @text = String.new(encoding: Encoding::UTF_8)
        @limit = limit
        @length = 0
        @escape = @overflowed = false
        @unicode = @high = nil
        @closed = false
      end

      def closed? = @closed

      def overflowed? = @overflowed

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
        return keep((0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)).chr(Encoding::UTF_8)) if
          high && code.between?(0xDC00, 0xDFFF)

        keep(REPLACEMENT) if high
        if code.between?(0xD800, 0xDBFF) then @high = code
        else keep(code.between?(0xDC00, 0xDFFF) ? REPLACEMENT : code.chr(Encoding::UTF_8))
        end
      end

      def append(text)
        keep(REPLACEMENT) if @high
        @high = nil
        keep(text) unless text.empty?
      end

      # One character more, unless past the limit.
      def keep(char)
        return @overflowed = true if @limit && @length >= @limit

        @length += 1
        @text << char
      end

      def close
        append("")
        @closed = true
      end
    end
  end
end
