# frozen_string_literal: true

require "dry-initializer"

require_relative "../diagnostic_text"
require_relative "../errors"

module Smith
  class Workflow
    class FailureRecordText
      # Deterministic stand-in shared by capture and restore for failure
      # messages that would otherwise be blank.
      MISSING_TEXT = "failure message unavailable"

      MODULE_MATCH = Module.instance_method(:===)
      STRING_BYTESIZE = String.instance_method(:bytesize)
      STRING_ENCODING = String.instance_method(:encoding)
      STRING_INITIALIZE_COPY = String.instance_method(:initialize_copy)
      STRING_VALID_ENCODING = String.instance_method(:valid_encoding?)
      SYMBOL_TO_S = Symbol.instance_method(:to_s)
      private_constant :MODULE_MATCH, :STRING_BYTESIZE, :STRING_ENCODING, :STRING_INITIALIZE_COPY,
                       :STRING_VALID_ENCODING, :SYMBOL_TO_S

      extend Dry::Initializer

      param :value
      option :limit
      option :label
      option :normalize_length, default: proc { false }

      def self.capture(value, limit:, label:, normalize_length: false)
        new(value, limit:, label:, normalize_length:).call
      end

      def call
        text = owned_text
        validate_encoding!(text)
        size = STRING_BYTESIZE.bind_call(text)
        return normalized(text, size) if normalize_length
        raise PersistedFailureInvalid, "persisted workflow failure #{label} is invalid" unless size.between?(1, limit)

        text.freeze
      end

      private

      def validate_encoding!(text)
        valid = STRING_VALID_ENCODING.bind_call(text) && STRING_ENCODING.bind_call(text) == Encoding::UTF_8
        return if valid

        raise PersistedFailureInvalid, "persisted workflow failure #{label} is invalid"
      end

      # Message fields mirror capture normalization instead of rejecting on
      # length: legacy states persisted messages unbounded (and possibly
      # blank), and failing the whole workflow restore for message length
      # alone would poison otherwise valid durable state. Blank text takes
      # the capture placeholder; overlong text truncates exactly like
      # capture does.
      def normalized(text, size)
        return MISSING_TEXT if size.zero?
        return text.freeze if size <= limit

        DiagnosticText.capture(text, max_bytes: limit)
      end

      def owned_text
        return owned_string if string?
        return SYMBOL_TO_S.bind_call(value) if symbol?

        raise PersistedFailureInvalid, "persisted workflow failure #{label} must be text"
      end

      def owned_string
        String.allocate.tap { STRING_INITIALIZE_COPY.bind_call(_1, value) }
      end

      def string? = MODULE_MATCH.bind_call(String, value)

      def symbol? = MODULE_MATCH.bind_call(Symbol, value)
    end
  end
end
