# frozen_string_literal: true

require_relative "provider_completion"
require_relative "usage_tracking"

module Smith
  class Agent
    module Lifecycle
      include ProviderCompletion
      include UsageTracking

      private

      def run_after_completion(agent_class, result, context)
        return result unless agent_class.method_defined?(:after_completion)

        instance = agent_class.allocate
        instance.after_completion(result, context)
      end

      def invoke_agent(agent_class, prepared_input, output_schema: agent_class.output_schema)
        check_deadline!
        completion, model_used = complete_with_provider(agent_class, prepared_input, output_schema:)
        snapshot_and_finalize(agent_class, completion, model_used)
      end
    end
  end
end
