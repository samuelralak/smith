# frozen_string_literal: true

module Smith
  class Agent
    module Lifecycle
      private

      def run_after_completion(agent_class, result, context)
        return result unless agent_class.method_defined?(:after_completion)

        instance = agent_class.allocate
        instance.after_completion(result, context)
      end

      def snapshot_and_finalize(agent_class, response)
        agent_result = Workflow::AgentResult.from_response(response, response&.content)
        Thread.current[:smith_last_agent_result] = agent_result

        agent_result.content = run_after_completion(agent_class, agent_result.content, @context)
        agent_result
      end
    end
  end
end
