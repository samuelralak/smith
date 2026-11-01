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
      # asks for until the response can be the output. The attempts set aside
      # on the way (`set_aside`) take what their tools captured with them
      # once there is an output (AttemptCaptures).
      def invoke_agent(agent_class, prepared_input, output_schema: effective_output_schema(agent_class))
        check_deadline!
        plan = output_plan(agent_class, prepared_input, output_schema)
        set_aside = []
        attempt = complete_with_provider(agent_class, prepared_input, shape: plan.shape, set_aside:)
        loop do
          result = account_attempt(agent_class, attempt.completion, attempt.model_reference,
                                   attempt_id: attempt.attempt_id)
          follow_up = output_follow_up(plan, attempt, result)
          return accepted_output(agent_class, result, set_aside) unless follow_up

          settle_rejected(result)
          set_aside.concat(attempt.captures)
          attempt = follow_up.call
        end
      end
    end
  end
end
