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
    end
  end
end
