# frozen_string_literal: true

require "dry-initializer"
require "json"

require_relative "../diagnostic_text"
require_relative "../errors"
require_relative "failure_record_text"
require_relative "failure_record_validator"
require_relative "message_value_normalizer"

module Smith
  class Workflow
    class FailureRecordRestore
      ATTRIBUTE_NAMES = %i[
        transition from to error_class error_family error_message error_retryable error_retry_forbidden
        error_kind error_details error_cause_class error_cause_family error_cause_message
      ].freeze
      OPTIONAL_NAMES = %i[error_retry_forbidden error_cause_class error_cause_family error_cause_message].freeze
      REQUIRED_NAMES = (ATTRIBUTE_NAMES - OPTIONAL_NAMES).freeze
      ATTRIBUTE_KEYS = ATTRIBUTE_NAMES.to_h { |name| [name.to_s, name] }.freeze
      MODULE_MATCH = Module.instance_method(:===)
      HASH_EACH_PAIR = Hash.instance_method(:each_pair)
      private_constant :ATTRIBUTE_NAMES, :OPTIONAL_NAMES, :REQUIRED_NAMES, :ATTRIBUTE_KEYS, :MODULE_MATCH,
                       :HASH_EACH_PAIR

      extend Dry::Initializer

      param :raw
      option :transition_normalizer
      option :state_normalizer

      def call
        return if raw.nil?

        reject!("persisted workflow failure record must be a Hash") unless MODULE_MATCH.bind_call(Hash, raw)

        values = attributes
        FailureRecordValidator.new(restored_record(values)).call
      end

      private

      def restored_record(values)
        identity_attributes(values).merge(error_attributes(values)).freeze
      end

      def identity_attributes(values)
        {
          transition: normalize_identifier(values.fetch(:transition), transition_normalizer, "transition"),
          from: normalize_identifier(values.fetch(:from), state_normalizer, "from state"),
          to: normalize_identifier(values.fetch(:to), state_normalizer, "to state")
        }
      end

      def error_attributes(values)
        {
          error_class: bounded_string(values.fetch(:error_class), 512, "class"),
          error_family: bounded_string(values.fetch(:error_family), 64, "family"),
          error_message: message_string(values.fetch(:error_message), "message"),
          error_retryable: boolean_or_nil(values.fetch(:error_retryable), "retryable"),
          error_retry_forbidden: boolean_or_nil(values[:error_retry_forbidden], "retry policy"),
          error_kind: normalize_kind(values.fetch(:error_kind)),
          error_details: normalize_details(values.fetch(:error_details)),
          **cause_attributes(values)
        }
      end

      def cause_attributes(values)
        {
          error_cause_class: optional_string(values[:error_cause_class], 512, "cause class"),
          error_cause_family: optional_string(values[:error_cause_family], 64, "cause family"),
          error_cause_message: optional_message(values[:error_cause_message], "cause message")
        }
      end

      def attributes
        values = {}
        HASH_EACH_PAIR.bind_call(raw) do |key, value|
          name = normalize_key(key)
          reject!("persisted workflow failure record contains a duplicate attribute") if values.key?(name)

          values[name] = value
        end
        missing = REQUIRED_NAMES - values.keys
        reject!("persisted workflow failure record is incomplete") if missing.any?
        values
      end

      def normalize_key(key)
        return key if symbol?(key) && ATTRIBUTE_NAMES.include?(key)
        return ATTRIBUTE_KEYS.fetch(key) if string?(key) && ATTRIBUTE_KEYS.key?(key)

        reject!("persisted workflow failure record contains an unknown attribute")
      end

      def normalize_identifier(value, normalizer, label)
        bounded_string(value, 256, label).then { normalizer.call(_1) }
      end

      def normalize_kind(value)
        return if value.nil?

        bounded_string(value, 256, "kind").to_sym
      end

      def normalize_details(value)
        return if value.nil?

        snapshot = MessageValueNormalizer.new(value, label: "persisted workflow failure details").call
        JSON.generate(snapshot)
        snapshot
      rescue WorkflowError, JSON::GeneratorError, EncodingError
        reject!("persisted workflow failure details are invalid")
      end

      def bounded_string(value, limit, label)
        FailureRecordText.capture(value, limit:, label:)
      end

      def optional_string(value, limit, label) = value.nil? ? nil : bounded_string(value, limit, label)

      # Messages restore with capture normalization (placeholder for blank
      # text, capture-identical truncation for overlong text) because legacy
      # states persisted them unbounded; length alone never rejects restore.
      def message_string(value, label)
        FailureRecordText.capture(value, limit: DiagnosticText::MAX_BYTES, label:, normalize_length: true)
      end

      def optional_message(value, label) = value.nil? ? nil : message_string(value, label)

      def boolean_or_nil(value, label)
        return value if value.nil? || value == true || value == false

        reject!("persisted workflow failure #{label} is invalid")
      end

      def reject!(message) = raise(Smith::PersistedFailureInvalid, message)

      def string?(value) = MODULE_MATCH.bind_call(String, value)

      def symbol?(value) = MODULE_MATCH.bind_call(Symbol, value)
    end
  end
end
