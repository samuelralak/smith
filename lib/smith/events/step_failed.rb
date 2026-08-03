# frozen_string_literal: true

module Smith
  module Events
    # Emitted from both step-failure paths (step-body failure and an
    # unresolved transition routed to :fail), closing the success-only
    # observation gap for failures that reach step handling. Terminal errors
    # raised outside it (an unresolved transition with no :fail transition,
    # transition-budget exhaustion, origin validation) still re-raise
    # without a StepFailed. Carries bounded classification only, never raw
    # error messages; `error_family` uses FailureRecord's taxonomy
    # ("agent_error", "deadline_exceeded", ..., "other") and `retryable` is
    # nil when the error does not declare retryability.
    class StepFailed < Smith::Event
      attribute :transition, Types::Strict::Symbol
      attribute :from, Types::Strict::Symbol.optional
      attribute :to, Types::Strict::Symbol.optional
      attribute :error_class, Types::Strict::String
      attribute :error_family, Types::Strict::String
      attribute :retryable, Types::Strict::Bool.optional
      # See StepCompleted#workflow.
      attribute :workflow, Types::Strict::String.optional.default(nil)
    end
  end
end
