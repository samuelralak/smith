# frozen_string_literal: true

require_relative "output_integrity"
require_relative "provider_completion"
require_relative "usage_tracking"

module Smith
  class Agent
    module Lifecycle
      include ProviderCompletion
      include UsageTracking
      include OutputIntegrity

      private

      def run_after_completion(agent_class, result, context)
        return result unless agent_class.method_defined?(:after_completion)

        instance = agent_class.allocate
        instance.after_completion(result, context)
      end

      # One invocation: the provider call, then whatever OutputIntegrity
      # asks for until the response can be the output.
      def invoke_agent(agent_class, prepared_input, output_schema: effective_output_schema(agent_class))
        check_deadline!
        plan = output_plan(agent_class, prepared_input, output_schema)
        attempt = complete_with_provider(agent_class, prepared_input, shape: plan.shape)
        loop do
          result = account_attempt(agent_class, attempt.completion, attempt.model_reference,
                                   attempt_id: attempt.attempt_id)
          follow_up = output_follow_up(plan, attempt, result)
          return finalize_output(agent_class, result) unless follow_up

          settle_rejected(result)
          attempt = follow_up.call
        end
      end
    end
  end
end
