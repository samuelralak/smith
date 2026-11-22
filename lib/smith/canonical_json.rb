# frozen_string_literal: true

require_relative "error"

module Smith
  # RFC 8785 canonical JSON (JCS): one byte form for a JSON value, so the
  # same value hashes the same in any process and any language. Every Smith
  # digest hashes it. Pure, and not loaded by `require "smith"`.
  #
  # Takes nil, true, false, Integer, Float, String, Symbol (as its name),
  # Array, and Hash with String or Symbol keys; anything else raises Error.
  # Members sort by their keys' UTF-16 code units; strings escape as
  # ECMAScript's JSON.stringify does; numbers follow ECMAScript's
  # Number-to-String on Ruby's shortest round-trip digits. Integers past
  # 2**53 - 1 raise (I-JSON: another language would round them), as do
  # NaN, Infinity and strings that are not valid UTF-8.
  #
  # O(N + sum k_i log k_i) time for N values and k_i keys per object, and
  # O(depth) stack, within the bounds below.
  module CanonicalJSON
    class Error < Smith::Error; end

    MAX_DEPTH = 64
    MAX_VALUES = 1_000_000
    MAX_BYTES = 64 * 1024 * 1024
    MAX_SAFE_INTEGER = (2**53) - 1

    ESCAPES = (0x00..0x1f).to_h { |code| [code.chr, format("\\u%04x", code)] }
                          .merge("\b" => "\\b", "\t" => "\\t", "\n" => "\\n", "\f" => "\\f", "\r" => "\\r",
                                 '"' => '\\"', "\\" => "\\\\").freeze
    ESCAPED = /["\\\x00-\x1f]/
    private_constant :ESCAPES, :ESCAPED

    def self.generate(value)
      Writer.new.result(value)
    end

    # One generate call's output and counts.
    class Writer
      def initialize
        @out = String.new(encoding: Encoding::UTF_8)
        @values = 0
      end

      def result(value)
        write(value, 0)
        @out
      end

      private

      def write(value, depth)
        @values += 1
        raise Error, "canonical JSON holds at most #{MAX_VALUES} values" if @values > MAX_VALUES

        case value
        when Hash then write_object(value, depth + 1)
        when Array then write_array(value, depth + 1)
        else append(Text.scalar(value))
        end
      end

      def write_object(hash, depth)
        within!(depth)
        append("{")
        Text.sorted_members(hash).each_with_index do |(key, member), index|
          append(",") unless index.zero?
          append(Text.string(key))
          append(":")
          write(member, depth)
        end
        append("}")
      end

      def write_array(array, depth)
        within!(depth)
        append("[")
        array.each_with_index do |item, index|
          append(",") unless index.zero?
          write(item, depth)
        end
        append("]")
      end

      def within!(depth)
        raise Error, "canonical JSON nests at most #{MAX_DEPTH} deep" if depth > MAX_DEPTH
      end

      def append(text)
        @out << text
        raise Error, "canonical JSON is at most #{MAX_BYTES} bytes" if @out.bytesize > MAX_BYTES
      end
    end
    private_constant :Writer

    # Scalars, strings and member order.
    module Text
      LITERALS = { true => "true", false => "false", nil => "null" }.freeze

      class << self
        def scalar(value)
          return LITERALS[value] if LITERALS.key?(value)

          case value
          when String then string(value)
          when Symbol then string(value.name)
          when Integer then integer(value)
          when Float then float(value)
          else raise Error, "canonical JSON cannot hold a #{value.class}"
          end
        end

        # Keys as UTF-8 Strings, ordered by UTF-16 code units (UTF-16BE bytes
        # compare in that order). Two keys equal after conversion raise.
        def sorted_members(hash)
          members = hash.map { |key, member| [key_text(key), member] }
          members.sort_by! { |key, _| key.encode(Encoding::UTF_16BE).b }
          members.each_cons(2) do |(left, _), (right, _)|
            raise Error, "canonical JSON object has the key #{left.inspect} twice" if left == right
          end
          members
        end

        def string(text)
          "\"#{utf8(text).gsub(ESCAPED, ESCAPES)}\""
        end

        private

        def key_text(key)
          case key
          when String then utf8(key)
          when Symbol then utf8(key.name)
          else raise Error, "canonical JSON object keys are Strings or Symbols, not #{key.class}"
          end
        end

        def utf8(text)
          return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?
          return text.dup.force_encoding(Encoding::UTF_8) if text.ascii_only?

          raise Error, "canonical JSON strings must be valid UTF-8"
        end

        def integer(number)
          raise Error, "canonical JSON integers are at most 2**53 - 1 in size" if number.abs > MAX_SAFE_INTEGER

          number.to_s
        end

        def float(number)
          raise Error, "canonical JSON numbers must be finite" unless number.finite?
          return "0" if number.zero?

          text = ecmascript(*shortest_digits(number.abs))
          number.negative? ? "-#{text}" : text
        end

        # Ruby's shortest round-trip spelling as digits d1..dk and the decimal
        # exponent n, so the value is 0.d1..dk * 10**n.
        def shortest_digits(number)
          mantissa, exponent = number.to_s.split("e")
          whole, fraction = mantissa.split(".")
          all = whole + fraction.to_s
          lead = all[/\A0*/].length
          [all[lead..].sub(/0+\z/, ""), whole.length - lead + exponent.to_i]
        end

        def ecmascript(digits, exponent)
          count = digits.length
          if exponent.between?(count, 21)
            digits + ("0" * (exponent - count))
          elsif exponent.positive? && exponent <= 21
            "#{digits[0, exponent]}.#{digits[exponent..]}"
          elsif exponent > -6 && exponent <= 0
            "0.#{"0" * -exponent}#{digits}"
          else
            scientific(digits, exponent - 1)
          end
        end

        def scientific(digits, power)
          mantissa = digits.length == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
          "#{mantissa}e#{power.negative? ? "-" : "+"}#{power.abs}"
        end
      end
    end
    private_constant :Text
  end
end
