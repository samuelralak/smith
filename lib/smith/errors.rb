# frozen_string_literal: true

module Smith
  module Errors; end

  class BudgetExceeded < Error; end
  class DeadlineExceeded < Error; end
  class MaxTransitionsExceeded < Error; end
  class GuardrailFailed < Error; end
  class ToolGuardrailFailed < Error; end
  class ToolPolicyDenied < Error; end
  class AgentError < Error; end
  class WorkflowError < Error; end
  class SerializationError < Error; end
end
