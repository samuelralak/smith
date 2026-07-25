# frozen_string_literal: true

require "dry-initializer"

module Smith
  class DiagnosticText
    MAX_BYTES = 64 * 1024
    TRUNCATION_MARKER = "...[truncated]"
    STRING_BYTESIZE = String.instance_method(:bytesize)
    STRING_BYTESLICE = String.instance_method(:byteslice)
    MODULE_MATCH = Module.instance_method(:===)
    private_constant :TRUNCATION_MARKER, :STRING_BYTESIZE, :STRING_BYTESLICE, :MODULE_MATCH

    extend Dry::Initializer

    param :value
    option :max_bytes, default: proc { MAX_BYTES }

    def self.capture(value, max_bytes: MAX_BYTES) = new(value, max_bytes:).call

    def call
      validate_limit!
      text = utf8_prefix
      return text.freeze if text.bytesize <= max_bytes

      truncate(text)
    end

    private

    def validate_limit!
      return if max_bytes.is_a?(Integer) && max_bytes >= TRUNCATION_MARKER.bytesize

      raise ArgumentError, "diagnostic text limit is too small"
    end

    def utf8_prefix
      source = string_value
      limit = (max_bytes * 4) + TRUNCATION_MARKER.bytesize
      prefix = STRING_BYTESLICE.bind_call(source, 0, limit)
      prefix.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    rescue EncodingError
      "unavailable diagnostic text"
    end

    def string_value
      return value if MODULE_MATCH.bind_call(String, value)

      String(value)
    rescue StandardError
      "unavailable diagnostic text"
    end

    def truncate(text)
      budget = max_bytes - TRUNCATION_MARKER.bytesize
      prefix = +""

      text.each_char do |character|
        break if prefix.bytesize + character.bytesize > budget

        prefix << character
      end

      (prefix << TRUNCATION_MARKER).freeze
    end
  end
end
