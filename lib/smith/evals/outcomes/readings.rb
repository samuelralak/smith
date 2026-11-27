# frozen_string_literal: true

require_relative "../../interruptions"

module Smith
  module Evals
    module Outcomes
      # Each reading an error can have (slice-1a design, 6.3): [outcome,
      # reason code, by, retried, stops the run], by class and by Smith's
      # failure family, classes named so none is loaded to be compared.
      # Internal.
      module Readings
        CAUSE_DEPTH = Smith::Interruptions::CAUSE_DEPTH
        INFRASTRUCTURE = ->(code, retryable: true, stops: false) { [:error, code, "infrastructure", retryable, stops] }
        SUBJECT = ->(code) { [:subject_failed, code, "subject", false, false] }
        LIMIT = ->(code) { [:limit_hit, code, "subject", false, false] }
        DEFINITION = [:error, "definition_error", "subject", false, true].freeze
        # A trial the run stops on, which did not run: an error that would
        # stop every trial, or the host's budget ledger refusing it. Called
        # again, the run runs it.
        STOPPING = ->(code) { [:not_run, code, "infrastructure", false, true] }

        CLASSES = [
          ["Smith::ProviderCredentialsMissing", STOPPING.call("credentials_missing")],
          ["Smith::ProviderCredentialsError", STOPPING.call("credentials_lookup_failed")],
          ["Smith::Evals::HostUnavailable", STOPPING.call("host_unavailable")],
          ["Smith::ScrubbedError", INFRASTRUCTURE.call("scrubbed_error", retryable: false)]
        ].freeze
        REFUSALS = { key_refused: "key_refused", permission: "provider_permission" }.freeze
        PROVIDER_KINDS = { "key_refused" => "key_refused", "out_of_credit" => "out_of_credit",
                           "permission" => "provider_permission", "model_unavailable" => "model_unavailable" }.freeze
        UNAVAILABLE = %w[transient transport].freeze
        PERSISTENCE = %w[SerializationError PersistenceIOError PersistenceVersionConflict PersistenceSchemaMismatch
                         PersistencePayloadConflict StepInProgressOnRestore UnknownStateOnRestore
                         UnknownTransitionOnRestore SeedMismatch].map { "Smith::#{_1}" }.freeze
        DEFINITIONS = %w[UnroutedDeterministicStep UndeclaredContextKey ArtifactStoreMissing StreamSinkMissing
                         BatchQueueMissing BatchModeUnavailable].map { "Smith::#{_1}" }.freeze

        # A family's reading, or its classes' in order (nil: any other).
        FAMILIES = {
          "deterministic_step_failure" => SUBJECT.call("step_failed"),
          "tool_failure_notification_failed" => SUBJECT.call("tool_failed"),
          "tool_capture_failed" => SUBJECT.call("tool_failed"),
          "tool_outcome_uncertain" => SUBJECT.call("tool_outcome_uncertain"),
          "request_outcome_uncertain" => INFRASTRUCTURE.call("request_outcome_uncertain", retryable: false),
          "tool_execution_not_admitted" => SUBJECT.call("tool_not_admitted"),
          "bounded_completion_error" => SUBJECT.call("tool_loop_bound"),
          "persisted_failure_invalid" => INFRASTRUCTURE.call("persistence"),
          "tool_guardrail_failed" => SUBJECT.call("tool_guardrail_failed"),
          "deadline_exceeded" => LIMIT.call("deadline"),
          "budget_exceeded" => [["Smith::BudgetUnavailable", STOPPING.call("ledger_refused")],
                                [nil, LIMIT.call("budget")]],
          "guardrail_failed" => SUBJECT.call("guardrail_failed"),
          "output_failure" => [["Smith::OutputTruncated", SUBJECT.call("output_truncated")],
                               ["Smith::OutputRefused", SUBJECT.call("output_refused")],
                               ["Smith::OutputInvalid", SUBJECT.call("output_invalid")],
                               [nil, SUBJECT.call("output_unusable")]],
          "agent_error" => [["Smith::BlankAgentOutputError", SUBJECT.call("blank_output")],
                            ["Smith::BatchResultFailed", INFRASTRUCTURE.call("batch_result_failed")],
                            ["Smith::BatchRequestChanged", INFRASTRUCTURE.call("batch_request_changed")],
                            [nil, :agent_error]],
          "wait_timed_out" => SUBJECT.call("wait_timed_out"),
          "child_runs_failed" => SUBJECT.call("child_runs_failed"),
          "workflow_error" => [["Smith::ContentUnavailable", SUBJECT.call("content_unavailable")],
                               ["Smith::PersistedStateTooLarge", SUBJECT.call("state_too_large")],
                               ["Smith::BatchRequestInvalid", SUBJECT.call("provider_rejected_request")],
                               ["Smith::BudgetLedgerError", INFRASTRUCTURE.call("ledger_error")],
                               ["Smith::UnresolvedTransitionError", SUBJECT.call("unresolved_transition")],
                               *DEFINITIONS.map { [_1, DEFINITION] },
                               [nil, SUBJECT.call("workflow_error")]],
          "other" => [["Smith::MaxTransitionsExceeded", LIMIT.call("max_transitions")],
                      ["Smith::ToolPolicyDenied", SUBJECT.call("tool_denied")],
                      ["Smith::ToolDispatchRejected", SUBJECT.call("tool_denied")],
                      ["Smith::AgentRegistryError", DEFINITION],
                      ["Smith::PricingConfigurationError", STOPPING.call("configuration_error")],
                      ["Smith::Testing::UnstubbedCall", STOPPING.call("configuration_error")],
                      *PERSISTENCE.map { [_1, INFRASTRUCTURE.call("persistence")] },
                      [nil, SUBJECT.call("unhandled_error")]]
        }.freeze
      end
    end
  end
end
