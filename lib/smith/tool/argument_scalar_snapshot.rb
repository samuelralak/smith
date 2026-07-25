# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ArgumentScalarSnapshot
      STRING_BYTESIZE = String.instance_method(:bytesize)
      STRING_ENCODE = String.instance_method(:encode)
      STRING_VALID_ENCODING = String.instance_method(:valid_encoding?)
      MODULE_MATCH = Module.instance_method(:===)
      DECIMAL_DIGIT_LOWER_BOUND_NUMERATOR = 301
      DECIMAL_DIGIT_LOWER_BOUND_DENOMINATOR = 1_000

      private_constant :STRING_BYTESIZE, :STRING_ENCODE, :STRING_VALID_ENCODING, :MODULE_MATCH,
                       :DECIMAL_DIGIT_LOWER_BOUND_NUMERATOR, :DECIMAL_DIGIT_LOWER_BOUND_DENOMINATOR

      extend Dry::Initializer

      option :byte_counter
      option :byte_validator

      def copy(value)
        case value
        when String then copy_string(value)
        when Integer then copy_integer(value)
        when TrueClass, FalseClass, NilClass then count(value)
        when Float then copy_float(value)
        else
          raise Error, "tool arguments must contain JSON-compatible values"
        end
      end

      def copy_key(key)
        raise Error, "tool argument object keys must be strings or symbols" unless string?(key) || symbol?(key)

        normalized = if string?(key)
                       normalize_utf8(key)
                     else
                       normalize_utf8(Symbol.instance_method(:to_s).bind_call(key))
                     end
        byte_counter.call(normalized.bytesize)
        string?(key) ? normalized : key
      end

      private

      def copy_string(value)
        normalized = normalize_utf8(value)
        byte_counter.call(normalized.bytesize)
        normalized
      end

      def copy_float(value)
        raise Error, "tool arguments must contain finite numbers" unless value.finite?

        count(value)
      end

      def copy_integer(value)
        byte_validator.call(minimum_integer_bytes(value))
        count(value)
      end

      def count(value)
        byte_counter.call(value.to_s.bytesize)
        value
      end

      def minimum_integer_bytes(value)
        bits = value.bit_length
        digits = if bits.zero?
                   1
                 else
                   (((bits - 1) * DECIMAL_DIGIT_LOWER_BOUND_NUMERATOR) /
                    DECIMAL_DIGIT_LOWER_BOUND_DENOMINATOR) + 1
                 end
        value.negative? ? digits + 1 : digits
      end

      def normalize_utf8(value)
        byte_validator.call(STRING_BYTESIZE.bind_call(value))
        raise Encoding::InvalidByteSequenceError unless STRING_VALID_ENCODING.bind_call(value)

        encoded = STRING_ENCODE.bind_call(value, Encoding::UTF_8)
        normalized = String.new(encoded).freeze
        raise Encoding::InvalidByteSequenceError unless STRING_VALID_ENCODING.bind_call(normalized)

        normalized
      rescue EncodingError
        raise Error, "tool arguments must contain valid UTF-8 strings"
      end

      def string?(value) = MODULE_MATCH.bind_call(String, value)

      def symbol?(value) = MODULE_MATCH.bind_call(Symbol, value)
    end
  end
end
