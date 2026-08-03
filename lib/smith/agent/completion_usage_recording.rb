# frozen_string_literal: true

module Smith
  class Agent
    module CompletionUsageRecording
      private

      # Returns [invocation_cost, fully_priced]. The cost is the sum of the
      # recorded entries' costs (nil when nothing was priced): per-response
      # pricing is what tiered catalogs bill, so the invocation cost comes
      # from this sum, never from pricing the aggregate token totals (which
      # would resolve the wrong tier for multi-response tool loops).
      # fully_priced is true only when every provider response carried usage
      # and every usage priced; a partial sum is still returned (it is what
      # was verifiably billed) but callers must not present it as the
      # complete invocation cost.
      def record_completion_usage(agent_class, completion, attempt_kind, model_reference, attempt_id: nil)
        model_reference = coerce_model_reference(model_reference)
        costs = completion.provider_usages.map do |usage|
          result = Workflow::AgentResult.new(
            content: nil,
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens,
            cost: nil,
            model_used: model_reference.model_id,
            provider_used: model_reference.provider
          )
          compute_agent_cost(result)
          record_usage(agent_class, result, attempt_kind, model_reference, attempt_id:)
          result.cost
        end
        summarize_invocation_costs(costs, completion)
      end

      def summarize_invocation_costs(costs, completion)
        priced = costs.compact
        invocation_cost = priced.empty? ? nil : priced.sum
        fully_priced = completion.usage_complete && !costs.empty? && priced.length == costs.length
        [invocation_cost, fully_priced]
      end
    end
  end
end
