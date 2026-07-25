# frozen_string_literal: true

require "dry-initializer"

require_relative "../errors"
require_relative "failure_record_validator"

module Smith
  class Workflow
    class FailureReconstructor
      FAMILY_BUILDERS = {
        "deterministic_step_failure" => ->(record) { deterministic_step_failure(record) },
        "tool_guardrail_failed" => ->(record) { tool_guardrail_failure(record) },
        "tool_failure_notification_failed" => ->(record) { tool_failure_notification_failure(record) },
        "tool_capture_failed" => ->(record) { Smith::ToolCaptureFailed.from_details(record.fetch(:error_details)) },
        "tool_outcome_uncertain" => ->(record) { Smith::ToolOutcomeUncertain.new(record[:error_message]) },
        "tool_execution_not_admitted" => ->(record) { Smith::ToolExecutionNotAdmitted.new(record[:error_message]) },
        "bounded_completion_error" => ->(record) { Smith::BoundedCompletionError.new(record[:error_message]) },
        "persisted_failure_invalid" => ->(record) { Smith::PersistedFailureInvalid.new(record[:error_message]) },
        "deadline_exceeded" => ->(record) { Smith::DeadlineExceeded.new(record[:error_message]) },
        "agent_error" => ->(record) { Smith::AgentError.new(record[:error_message]) },
        "workflow_error" => ->(record) { Smith::WorkflowError.new(record[:error_message]) },
        "other" => ->(record) { RuntimeError.new(record[:error_message]) }
      }.freeze
      SPECIAL_CLASS_BUILDERS = {
        "Smith::Workflow::Composite::BranchFailure" => lambda { |record|
          Smith::Workflow::Composite::BranchFailure.from_details(record[:error_details])
        }
      }.freeze
      private_constant :FAMILY_BUILDERS, :SPECIAL_CLASS_BUILDERS

      extend Dry::Initializer

      option :snapshot
      option :transition_normalizer
      option :state_normalizer

      def call
        {
          transition: transition_normalizer.call(snapshot[:transition]),
          from: state_normalizer.call(snapshot[:from]),
          to: state_normalizer.call(snapshot[:to]),
          error: reconstruct_error
        }
      end

      private

      def reconstruct_error
        FailureRecordValidator.new(snapshot).call
        builder = SPECIAL_CLASS_BUILDERS[snapshot[:error_class]] || FAMILY_BUILDERS.fetch(snapshot[:error_family])
        builder.call(snapshot)
      rescue Smith::PersistedFailureInvalid
        raise
      rescue ArgumentError, KeyError, TypeError
        raise Smith::PersistedFailureInvalid, "persisted workflow failure details are invalid"
      end

      def self.deterministic_step_failure(record)
        Smith::DeterministicStepFailure.new(
          record[:error_message],
          retryable: record[:error_retryable],
          kind: record[:error_kind],
          details: record[:error_details]
        )
      end

      def self.tool_guardrail_failure(record)
        Smith::ToolGuardrailFailed.new(record[:error_message], retryable: record[:error_retryable])
      end

      def self.tool_failure_notification_failure(record)
        Smith::ToolFailureNotificationFailed.from_details(record.fetch(:error_details))
      end

      private_class_method :deterministic_step_failure, :tool_guardrail_failure, :tool_failure_notification_failure
    end
  end
end
