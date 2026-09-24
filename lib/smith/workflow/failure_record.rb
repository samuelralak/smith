# frozen_string_literal: true

require "dry-initializer"

require_relative "../diagnostic_text"
require_relative "../errors"
require_relative "failure_detail_snapshot"
require_relative "failure_record_text"

module Smith
  class Workflow
    class FailureRecord
      ERROR_FAMILIES = [
        [Smith::DeterministicStepFailure, "deterministic_step_failure"],
        [Smith::ToolFailureNotificationFailed, "tool_failure_notification_failed"],
        [Smith::ToolCaptureFailed, "tool_capture_failed"],
        [Smith::ToolOutcomeUncertain, "tool_outcome_uncertain"],
        [Smith::ToolExecutionNotAdmitted, "tool_execution_not_admitted"],
        [Smith::BoundedCompletionError, "bounded_completion_error"],
        [Smith::PersistedFailureInvalid, "persisted_failure_invalid"],
        [Smith::ToolGuardrailFailed, "tool_guardrail_failed"],
        [Smith::DeadlineExceeded, "deadline_exceeded"],
        [Smith::ProviderPermanentFailure, "provider_permanent_failure"],
        [Smith::BudgetExceeded, "budget_exceeded"],
        [Smith::GuardrailFailed, "guardrail_failed"],
        [Smith::AgentError, "agent_error"],
        [Smith::WorkflowError, "workflow_error"]
      ].freeze
      BOOLEAN_VALUES = [true, false].freeze
      EXCEPTION_CAUSE = Exception.instance_method(:cause)
      EXCEPTION_MESSAGE = Exception.instance_method(:message)
      MODULE_MATCH = Module.instance_method(:===)
      private_constant :ERROR_FAMILIES, :BOOLEAN_VALUES, :EXCEPTION_CAUSE, :EXCEPTION_MESSAGE, :MODULE_MATCH

      extend Dry::Initializer

      option :step_result

      def self.capture(step_result) = new(step_result:).call

      def call
        error = step_result.fetch(:error)
        {
          transition: step_result[:transition],
          from: step_result[:from],
          to: step_result[:to],
          **error_attributes(error)
        }.freeze
      end

      private

      def error_attributes(error)
        {
          error_class: DiagnosticText.error_class_name(error),
          error_family: error_family(error),
          error_message: error_message(error),
          error_retryable: retryable_value(error),
          error_retry_forbidden: Smith::Errors.retry_forbidden?(error),
          error_kind: error_kind(error),
          error_details: error_details(error),
          **cause_attributes(error)
        }
      end

      # Uncertainty wrappers replace the causal failure at the transition
      # boundary; without this classification a restored host cannot
      # distinguish a deadline, cancellation, or defect behind an
      # uncertain tool outcome.
      def cause_attributes(error)
        cause = uncertainty_cause(error)
        {
          error_cause_class: cause && DiagnosticText.error_class_name(cause),
          error_cause_family: cause && error_family(cause),
          error_cause_message: cause && error_message(cause)
        }
      end

      def uncertainty_cause(error)
        return unless MODULE_MATCH.bind_call(Smith::ToolOutcomeUncertain, error)

        cause = EXCEPTION_CAUSE.bind_call(error)
        cause if MODULE_MATCH.bind_call(Exception, cause)
      rescue StandardError
        nil
      end

      def error_family(error)
        ERROR_FAMILIES.find { |error_class, _| MODULE_MATCH.bind_call(error_class, error) }&.last || "other"
      end

      # Never captures blank text: restore requires non-empty messages, so
      # a blank live message takes the shared deterministic placeholder.
      def error_message(error)
        captured = DiagnosticText.capture(EXCEPTION_MESSAGE.bind_call(error))
        captured.empty? ? FailureRecordText::MISSING_TEXT : captured
      rescue StandardError
        FailureRecordText::MISSING_TEXT
      end

      def retryable_value(error)
        return unless error.respond_to?(:retryable)

        value = error.retryable
        value if BOOLEAN_VALUES.include?(value)
      rescue StandardError
        nil
      end

      def error_kind(error)
        return unless error.respond_to?(:kind)

        value = error.kind
        return unless value.is_a?(String) || value.is_a?(Symbol)

        captured = DiagnosticText.capture(value.to_s, max_bytes: 256)
        # Restore rejects blank kinds; an empty kind carries no signal.
        captured unless captured.empty?
      rescue StandardError
        nil
      end

      def error_details(error)
        return unless error.respond_to?(:details)

        FailureDetailSnapshot.new(error.details).call
      rescue StandardError => e
        FailureDetailSnapshot.new(
          smith_failure_details_omitted: DiagnosticText.capture(e.message, max_bytes: 1_024)
        ).call
      end
    end
  end
end
