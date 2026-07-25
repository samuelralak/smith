# frozen_string_literal: true

module Smith
  class Agent
    module CompletionUsageRecording
      private

      def record_completion_usage(agent_class, completion, attempt_kind, model_reference)
        model_reference = coerce_model_reference(model_reference)
        completion.provider_usages.each do |usage|
          result = Workflow::AgentResult.new(
            content: nil,
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens,
            cost: nil,
            model_used: model_reference.model_id,
            provider_used: model_reference.provider
          )
          compute_agent_cost(result)
          record_usage(agent_class, result, attempt_kind, model_reference)
        end
      end
    end
  end
end
