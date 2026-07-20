# frozen_string_literal: true

require_relative "../../types"
require_relative "../../tool_capture_failed"
require_relative "payload"

module Smith
  class Workflow
    module Composite
      class Error < Payload
        FAMILIES = %w[
          tool_capture_failed tool_guardrail_failed deterministic_step_failure
          deadline_exceeded agent_error workflow_error other
        ].freeze
        ALWAYS_RETRYABLE_FAMILIES = %w[deadline_exceeded agent_error].freeze
        CONDITIONALLY_RETRYABLE_FAMILIES = %w[tool_guardrail_failed deterministic_step_failure].freeze
        OPTIONAL_METADATA = %i[tool_name reason].freeze
        STRING_METADATA = %i[kind tool_name reason].freeze
        private_constant :ALWAYS_RETRYABLE_FAMILIES, :CONDITIONALLY_RETRYABLE_FAMILIES
        private_constant :OPTIONAL_METADATA, :STRING_METADATA
        OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
        private_constant :OwnedString

        attribute :class_name, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :family, OwnedString.enum(*FAMILIES)
        attribute :retryable, Types::Bool
        attribute? :kind, OwnedString.constrained(min_size: 1, max_size: 128).optional
        attribute? :tool_name, OwnedString.constrained(min_size: 1, max_size: 256).optional
        attribute? :reason, OwnedString.constrained(min_size: 1, max_size: 128).optional

        class << self
          def normalize_attributes(attributes)
            return super unless attributes.is_a?(Hash)

            super(attributes_with_optional_metadata(attributes))
          end

          private

          def attributes_with_optional_metadata(attributes)
            values = {}
            Hash.instance_method(:each_pair).bind_call(attributes) { |key, value| values[key] = value }
            OPTIONAL_METADATA.each do |name|
              values[name] = nil unless values.key?(name) || values.key?(name.to_s)
            end
            values
          end
        end

        def initialize(attributes)
          super(normalize_error_attributes(attributes))
          validate_retryability!
          validate_kind!
          validate_tool_capture_metadata!
        end

        private

        def normalize_error_attributes(attributes)
          self.class.normalize_attributes(attributes).tap do |normalized|
            STRING_METADATA.each { |name| normalized[name] = normalized[name].to_s if normalized[name] }
          end
        end

        def validate_retryability!
          valid = if ALWAYS_RETRYABLE_FAMILIES.include?(family)
                    retryable
                  elsif CONDITIONALLY_RETRYABLE_FAMILIES.include?(family)
                    [true, false].include?(retryable)
                  else
                    !retryable
                  end
          raise ArgumentError, "composite error retryability does not match its family" unless valid
        end

        def validate_kind!
          return if kind.nil? || family == "deterministic_step_failure"

          raise ArgumentError, "composite error kind is not valid for its family"
        end

        def validate_tool_capture_metadata!
          valid = if family == "tool_capture_failed"
                    valid_tool_capture_metadata?
                  else
                    tool_name.nil? && reason.nil?
                  end
          return if valid

          raise ArgumentError, "composite error tool metadata does not match its family"
        end

        def valid_tool_capture_metadata?
          ToolCaptureFailed.from_details(tool_name:, reason:)
          true
        rescue ArgumentError
          false
        end
      end
    end
  end
end
