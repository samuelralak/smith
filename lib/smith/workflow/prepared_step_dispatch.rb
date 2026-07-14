# frozen_string_literal: true

require "dry-struct"
require "json"

require_relative "../types"
require_relative "prepared_step"

module Smith
  class Workflow
    class PreparedStepDispatch < Dry::Struct
      ATTRIBUTES = %i[prepared_step token dispatch_digest].freeze
      MAX_ATTRIBUTE_ENTRIES = 8
      MAX_SERIALIZED_BYTES = 8 * 1024
      OwnedString = Types::String.constructor do |value|
        value.is_a?(String) ? value.dup.freeze : value
      end
      private_constant :OwnedString

      attribute :prepared_step, Types.Instance(PreparedStep)
      attribute :token, OwnedString.constrained(format: PreparedStep::UUID_PATTERN)
      attribute :dispatch_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)

      def self.deserialize(value)
        attributes = parse_attributes(value)
        normalized = normalize_attributes(attributes)
        validate_attributes!(normalized)
        normalized[:prepared_step] = PreparedStep.deserialize(normalized[:prepared_step])
        new(normalized)
      rescue JSON::ParserError, TypeError => e
        raise ArgumentError, "prepared-step dispatch is invalid: #{e.message}"
      end

      def self.parse_attributes(value)
        return value if value.is_a?(Hash) && bounded_hash?(value)
        unless value.is_a?(String) && value.bytesize <= MAX_SERIALIZED_BYTES
          raise ArgumentError, "prepared-step dispatch must be a bounded Hash or JSON object"
        end

        parsed = JSON.parse(value)
        return parsed if parsed.is_a?(Hash) && bounded_hash?(parsed)

        raise ArgumentError, "prepared-step dispatch JSON must contain a bounded object"
      end
      private_class_method :parse_attributes

      def self.bounded_hash?(attributes)
        return false unless attributes.size <= MAX_ATTRIBUTE_ENTRIES
        return false unless attributes.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }

        attributes.sum { |key, value| key.to_s.bytesize + bounded_value_bytes(value) } <= MAX_SERIALIZED_BYTES
      end
      private_class_method :bounded_hash?

      def self.bounded_value_bytes(value)
        return value.bytesize if value.is_a?(String)
        return PreparedStep::MAX_SERIALIZED_BYTES if value.is_a?(Hash)

        MAX_SERIALIZED_BYTES + 1
      end
      private_class_method :bounded_value_bytes

      def self.normalize_attributes(attributes)
        attributes.each_with_object({}) do |(key, value), result|
          normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          raise ArgumentError, "prepared-step dispatch contains duplicate attributes" if result.key?(normalized_key)

          result[normalized_key] = value
        end
      end
      private_class_method :normalize_attributes

      def self.validate_attributes!(attributes)
        unknown = attributes.keys - ATTRIBUTES
        missing = ATTRIBUTES - attributes.keys
        raise ArgumentError, "prepared-step dispatch contains unknown attributes: #{unknown.join(", ")}" if unknown.any?
        raise ArgumentError, "prepared-step dispatch is missing attributes: #{missing.join(", ")}" if missing.any?
      end
      private_class_method :validate_attributes!

      def initialize(attributes)
        super
        self.attributes.freeze
        freeze
      end
    end
  end
end
