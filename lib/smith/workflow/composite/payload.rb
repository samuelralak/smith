# frozen_string_literal: true

require "dry-struct"
require "json"

require_relative "../message_value_normalizer"

module Smith
  class Workflow
    module Composite
      class Payload < Dry::Struct
        MAX_SERIALIZED_BYTES = MessageValueNormalizer::MAX_BYTES
        HASH_EACH_PAIR = Hash.instance_method(:each_pair)
        private_constant :HASH_EACH_PAIR

        class << self
          def deserialize(value)
            attributes = parse_attributes(value)
            preflight_attributes!(attributes)
            bounded = MessageValueNormalizer.new(attributes, label: payload_name).call
            new(normalize_attributes(bounded))
          rescue JSON::ParserError, TypeError => e
            raise ArgumentError, "#{payload_name} is invalid: #{e.message}"
          end

          def normalize_attributes(attributes)
            raise ArgumentError, "#{payload_name} must contain an object" unless attributes.is_a?(Hash)

            result = normalize_attribute_keys(attributes)
            validate_known_attributes!(result)
            result
          end

          def payload_name
            name.split("::").last.gsub(/([a-z])([A-Z])/, '\\1-\\2').downcase
          end

          def preflight_attributes!(attributes) = attributes

          private

          def normalize_attribute_keys(attributes)
            result = {}
            HASH_EACH_PAIR.bind_call(attributes) do |key, value|
              normalized_key = normalize_attribute_key(key)
              raise ArgumentError, "#{payload_name} contains duplicate attributes" if result.key?(normalized_key)

              result[normalized_key] = value
            end
            result
          end

          def normalize_attribute_key(key)
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ArgumentError, "#{payload_name} attribute names must be strings or symbols"
            end

            return key if key.is_a?(Symbol)

            payload_attribute_lookup.fetch(key) { key.dup.freeze }
          end

          def validate_known_attributes!(attributes)
            unknown = attributes.keys - payload_attribute_names
            missing = payload_attribute_names - attributes.keys
            raise ArgumentError, "#{payload_name} contains unknown attributes: #{unknown.join(", ")}" if unknown.any?
            return if missing.empty?

            raise ArgumentError, "#{payload_name} is missing attributes: #{missing.join(", ")}"
          end

          def payload_attribute_names
            @payload_attribute_names ||= schema.keys.map(&:name).freeze
          end

          def payload_attribute_lookup
            @payload_attribute_lookup ||= payload_attribute_names.to_h do |name|
              [name.to_s.freeze, name]
            end.freeze
          end

          def raw_attribute(attributes, name)
            symbol_present = Hash.instance_method(:key?).bind_call(attributes, name)
            string_present = Hash.instance_method(:key?).bind_call(attributes, name.to_s)
            raise ArgumentError, "#{payload_name} contains duplicate attributes" if symbol_present && string_present

            Hash.instance_method(:[]).bind_call(attributes, symbol_present ? name : name.to_s)
          end

          def parse_attributes(value)
            return value if value.is_a?(Hash)
            unless value.is_a?(String) && value.bytesize <= MAX_SERIALIZED_BYTES
              raise ArgumentError, "#{payload_name} must be a bounded Hash or JSON object"
            end

            JSON.parse(value).tap do |parsed|
              raise ArgumentError, "#{payload_name} JSON must contain an object" unless parsed.is_a?(Hash)
            end
          end
        end

        def serialize
          JSON.generate(to_h).tap do |payload|
            raise WorkflowError, "#{self.class.payload_name} exceeds maximum bytes" if
              payload.bytesize > self.class::MAX_SERIALIZED_BYTES
          end
        end

        def initialize(attributes)
          super
          validate_serialized_size!
          self.attributes.freeze
          freeze
        end

        private

        def validate_serialized_size!
          return if JSON.generate(to_h).bytesize <= self.class::MAX_SERIALIZED_BYTES

          raise ArgumentError, "#{self.class.payload_name} exceeds maximum encoded bytes"
        end
      end

      private_constant :Payload
    end
  end
end
