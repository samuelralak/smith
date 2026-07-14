# frozen_string_literal: true

require "dry-struct"
require "json"

require_relative "../types"

module Smith
  class Workflow
    class PreparedStep < Dry::Struct
      ATTRIBUTES = %i[
        token transition from persistence_key persistence_version step_number preparation_digest definition_digest
      ].freeze
      DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
      MAX_COUNTER_VALUE = (2**63) - 1
      MAX_ATTRIBUTE_ENTRIES = 16
      MAX_SERIALIZED_BYTES = 4 * 1024
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
      OwnedString = Types::String.constructor do |value|
        value.is_a?(String) ? value.dup.freeze : value
      end
      private_constant :OwnedString

      attribute :token, OwnedString.constrained(format: UUID_PATTERN)
      attribute :transition, OwnedString.constrained(min_size: 1)
      attribute :from, OwnedString.constrained(min_size: 1)
      attribute :persistence_key, OwnedString.constrained(min_size: 1)
      attribute :persistence_version, Types::Integer.constrained(gteq: 1, lteq: MAX_COUNTER_VALUE)
      attribute :step_number, Types::Integer.constrained(gteq: 1, lteq: MAX_COUNTER_VALUE)
      attribute :preparation_digest, OwnedString.constrained(format: DIGEST_PATTERN)
      attribute? :definition_digest, Types::Sha256Hex.optional

      def self.deserialize(value)
        attributes = parse_attributes(value)
        normalized = normalize_attributes(attributes)
        validate_attributes!(normalized)
        validate_bounded_values!(normalized)
        new(normalized)
      rescue JSON::ParserError, TypeError => e
        raise ArgumentError, "prepared step is invalid: #{e.message}"
      end

      def self.validate_attributes!(attributes)
        unknown = attributes.keys - ATTRIBUTES
        missing = ATTRIBUTES.first(7) - attributes.keys
        raise ArgumentError, "prepared step contains unknown attributes: #{unknown.join(", ")}" if unknown.any?
        raise ArgumentError, "prepared step is missing attributes: #{missing.join(", ")}" if missing.any?
      end
      private_class_method :validate_attributes!

      def self.parse_attributes(value)
        return validate_attribute_container!(value) if value.is_a?(Hash)
        unless value.is_a?(String) && value.bytesize <= MAX_SERIALIZED_BYTES
          raise ArgumentError, "prepared step must be a Hash or bounded JSON object"
        end

        parsed = JSON.parse(value)
        return validate_attribute_container!(parsed) if parsed.is_a?(Hash)

        raise ArgumentError, "prepared step JSON must contain an object"
      end
      private_class_method :parse_attributes

      def self.validate_attribute_container!(attributes)
        unless attributes.size <= MAX_ATTRIBUTE_ENTRIES
          raise ArgumentError, "prepared step contains too many attributes"
        end
        unless attributes.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
          raise ArgumentError, "prepared step attribute names must be strings or symbols"
        end

        attributes
      end
      private_class_method :validate_attribute_container!

      def self.validate_bounded_values!(attributes)
        bytes = attributes.sum { |key, value| bounded_attribute_bytes(key, value) }
        return attributes if bytes <= MAX_SERIALIZED_BYTES

        raise ArgumentError, "prepared step Hash exceeds maximum bytes"
      end
      private_class_method :validate_bounded_values!

      def self.bounded_attribute_bytes(key, value)
        validate_scalar_value!(value)
        key.to_s.bytesize + (value.is_a?(String) ? value.bytesize : 8)
      end
      private_class_method :bounded_attribute_bytes

      def self.validate_scalar_value!(value)
        unless value.nil? || value.is_a?(String) || value.is_a?(Integer)
          raise ArgumentError, "prepared step attribute values must be scalar"
        end
        return unless value.is_a?(Integer) && !value.between?(1, MAX_COUNTER_VALUE)

        raise ArgumentError, "prepared step integer values must fit a positive signed 64-bit counter"
      end
      private_class_method :validate_scalar_value!

      def self.normalize_attributes(attributes)
        normalized = attributes.each_with_object({}) do |(key, nested), result|
          normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          raise ArgumentError, "prepared step contains duplicate attributes" if result.key?(normalized_key)

          result[normalized_key] = nested
        end
        normalized[:definition_digest] = nil unless normalized.key?(:definition_digest)
        normalized
      end
      private_class_method :normalize_attributes

      def initialize(attributes)
        owned = attributes.dup
        digest = owned[:definition_digest] || owned["definition_digest"]
        owned[:definition_digest] = digest.dup.freeze if digest.is_a?(String)
        super(owned)
        self.attributes.freeze
        freeze
      end
    end
  end
end
