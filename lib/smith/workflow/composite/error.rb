# frozen_string_literal: true

require_relative "../../types"
require_relative "payload"

module Smith
  class Workflow
    module Composite
      class Error < Payload
        FAMILIES = %w[
          tool_guardrail_failed deterministic_step_failure deadline_exceeded
          agent_error workflow_error other
        ].freeze
        ALWAYS_RETRYABLE_FAMILIES = %w[deadline_exceeded agent_error].freeze
        CONDITIONALLY_RETRYABLE_FAMILIES = %w[tool_guardrail_failed deterministic_step_failure].freeze
        private_constant :ALWAYS_RETRYABLE_FAMILIES, :CONDITIONALLY_RETRYABLE_FAMILIES
        OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
        private_constant :OwnedString

        attribute :class_name, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :family, OwnedString.enum(*FAMILIES)
        attribute :retryable, Types::Bool
        attribute? :kind, OwnedString.constrained(min_size: 1, max_size: 128).optional

        def initialize(attributes)
          owned = self.class.normalize_attributes(attributes)
          owned[:kind] = owned[:kind].to_s if owned[:kind]
          super(owned)
          validate_retryability!
          validate_kind!
        end

        private

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
      end
    end
  end
end
