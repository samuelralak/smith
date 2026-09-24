# frozen_string_literal: true

require "dry-initializer"

require_relative "../errors"
require_relative "composite/branch_failure"

module Smith
  class Workflow
    class FailureRecordValidator
      KNOWN_ERROR_FAMILIES = {
        "Smith::DeterministicStepFailure" => "deterministic_step_failure",
        "Smith::ToolGuardrailFailed" => "tool_guardrail_failed",
        "Smith::ToolCaptureFailed" => "tool_capture_failed",
        "Smith::ToolFailureNotificationFailed" => "tool_failure_notification_failed",
        "Smith::ToolOutcomeUncertain" => "tool_outcome_uncertain",
        "Smith::ToolExecutionNotAdmitted" => "tool_execution_not_admitted",
        "Smith::BoundedCompletionError" => "bounded_completion_error",
        "Smith::PersistedFailureInvalid" => "persisted_failure_invalid",
        "Smith::AgentError" => "agent_error",
        "Smith::BlankAgentOutputError" => "agent_error",
        "Smith::DeadlineExceeded" => "deadline_exceeded",
        "Smith::ProviderPermanentFailure" => "provider_permanent_failure",
        "Smith::BudgetExceeded" => "budget_exceeded",
        "Smith::GuardrailFailed" => "guardrail_failed",
        "Smith::WorkflowError" => "workflow_error",
        "Smith::UnresolvedTransitionError" => "workflow_error",
        "Smith::Workflow::Composite::BranchFailure" => "workflow_error"
      }.freeze
      # Records written before these classes had their own families carry
      # "other" and no details; they keep restoring exactly as they did.
      LEGACY_ERROR_FAMILIES = {
        "Smith::ProviderPermanentFailure" => "other",
        "Smith::BudgetExceeded" => "other",
        "Smith::GuardrailFailed" => "other"
      }.freeze
      KNOWN_FAMILIES = %w[
        deterministic_step_failure tool_guardrail_failed tool_failure_notification_failed tool_capture_failed
        tool_outcome_uncertain tool_execution_not_admitted bounded_completion_error persisted_failure_invalid
        deadline_exceeded provider_permanent_failure budget_exceeded guardrail_failed agent_error workflow_error
        other
      ].freeze
      RETRY_FORBIDDEN_FAMILIES = %w[
        tool_capture_failed tool_failure_notification_failed tool_outcome_uncertain tool_execution_not_admitted
        bounded_completion_error persisted_failure_invalid
      ].freeze
      DETAIL_VALIDATORS = {
        "Smith::ToolCaptureFailed" => ->(details) { Smith::ToolCaptureFailed.from_details(details) },
        "Smith::ToolFailureNotificationFailed" => lambda { |details|
          Smith::ToolFailureNotificationFailed.from_details(details)
        },
        "Smith::Workflow::Composite::BranchFailure" => lambda { |details|
          Smith::Workflow::Composite::BranchFailure.from_details(details)
        },
        "Smith::ProviderPermanentFailure" => ->(details) { Smith::ProviderPermanentFailure.from_details(details) },
        "Smith::BlankAgentOutputError" => lambda { |details|
          Smith::BlankAgentOutputError.from_details(details) unless details.nil?
        }
      }.freeze
      BOOLEAN_VALUES = [true, false].freeze
      private_constant :KNOWN_ERROR_FAMILIES, :LEGACY_ERROR_FAMILIES, :KNOWN_FAMILIES, :RETRY_FORBIDDEN_FAMILIES,
                       :DETAIL_VALIDATORS, :BOOLEAN_VALUES

      extend Dry::Initializer

      param :snapshot

      def call
        validate_family!
        validate_class_family!
        validate_retry_policy!
        validate_cause!
        validate_details!
        snapshot
      rescue ArgumentError, KeyError, TypeError
        reject!("persisted workflow failure details are invalid")
      end

      private

      def family = snapshot[:error_family]

      def validate_family!
        return if KNOWN_FAMILIES.include?(family)

        reject!("persisted workflow failure family is invalid")
      end

      def validate_class_family!
        expected = KNOWN_ERROR_FAMILIES[snapshot[:error_class]]
        return unless expected && family != expected
        return if legacy_family?

        reject!("persisted workflow failure class and family disagree")
      end

      def legacy_family? = LEGACY_ERROR_FAMILIES[snapshot[:error_class]] == family

      def validate_retry_policy!
        forbidden = snapshot[:error_retry_forbidden]
        return if forbidden.nil?

        reject!("persisted workflow failure retry policy is invalid") unless BOOLEAN_VALUES.include?(forbidden)
        return if forbidden == RETRY_FORBIDDEN_FAMILIES.include?(family)

        reject!("persisted workflow failure retry policy disagrees with its family")
      end

      # Cause classification travels as one unit: capture writes all three
      # attributes together for uncertainty wrappers, so a partial set is
      # corrupt data rather than a legacy shape (legacy records omit all
      # three).
      def validate_cause!
        cause_values = snapshot.values_at(:error_cause_class, :error_cause_family, :error_cause_message)
        return if cause_values.all?(&:nil?)

        reject!("persisted workflow failure cause is incomplete") if cause_values.any?(&:nil?)
        return if KNOWN_FAMILIES.include?(snapshot[:error_cause_family])

        reject!("persisted workflow failure cause family is invalid")
      end

      def validate_details!
        return if legacy_family?

        validator = DETAIL_VALIDATORS[snapshot[:error_class]]
        validator&.call(snapshot[:error_details])
      end

      def reject!(message) = raise(Smith::PersistedFailureInvalid, message)
    end
  end
end
