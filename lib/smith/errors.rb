# frozen_string_literal: true

module Smith
  module Errors; end

  class BudgetExceeded < Error; end
  class DeadlineExceeded < Error; end
  class MaxTransitionsExceeded < Error; end
  class GuardrailFailed < Error; end
  class ToolGuardrailFailed < Error
    attr_reader :retryable

    def initialize(message, retryable: nil)
      @retryable = retryable
      super(message)
    end
  end
  class ToolPolicyDenied < Error; end
  class AgentError < Error; end
  class WorkflowError < Error; end

  class DeterministicStepFailure < WorkflowError
    attr_reader :retryable, :kind, :details

    def initialize(message, retryable: nil, kind: nil, details: nil)
      @retryable = retryable
      @kind = kind
      @details = details
      super(message)
    end
  end

  class UnresolvedTransitionError < WorkflowError
    attr_reader :requested_name, :workflow_class, :origin_state

    def initialize(requested_name, workflow_class, origin_state)
      @requested_name = requested_name
      @workflow_class = workflow_class
      @origin_state = origin_state
      super("unresolved transition :#{requested_name} in #{workflow_class} from state :#{origin_state}")
    end
  end

  class SerializationError < Error; end
end
