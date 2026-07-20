# frozen_string_literal: true

require "dry-initializer"

require_relative "../../errors"
require_relative "error"

module Smith
  class Workflow
    module Composite
      class ErrorEvidence
        extend Dry::Initializer

        param :error

        def self.call(error) = new(error).call

        def call
          Error.new(
            class_name: error_class_name,
            family: error_family,
            retryable: retryable_error?,
            kind: error_kind
          )
        end

        private

        def error_class_name
          value = error.class.name.to_s
          value.empty? || value.length > 256 ? "StandardError" : value
        end

        def retryable_error?
          Errors.retryable?(error)
        end

        def error_kind
          return unless error.is_a?(DeterministicStepFailure)

          value = error.kind
          string = value.to_s if value
          string if string&.length&.between?(1, 128)
        rescue StandardError
          nil
        end

        def error_family
          case error
          when ToolGuardrailFailed then "tool_guardrail_failed"
          when DeterministicStepFailure then "deterministic_step_failure"
          when DeadlineExceeded then "deadline_exceeded"
          when AgentError then "agent_error"
          when WorkflowError then "workflow_error"
          else "other"
          end
        end
      end
    end
  end
end
