# frozen_string_literal: true

module Smith
  class Agent
    module CompletionUsageRecording
      private

      # Records and prices one usage entry per provider response and returns
      # the per-response AgentResults: per-response pricing is what tiered
      # catalogs bill, so an invocation's cost is the sum of these, never the
      # aggregate token totals priced as one call (which would resolve the
      # wrong tier for a multi-response tool loop).
      def record_response_usages(agent_class, usages, attempt_kind, model_reference, attempt_id: nil)
        model_reference = coerce_model_reference(model_reference)
        usages.map do |usage|
          result = Workflow::AgentResult.new(
            content: nil,
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens,
            cost: nil,
            model_used: model_reference.model_id,
            provider_used: model_reference.provider,
            **Workflow::AgentResult.usage_details(usage)
          )
          compute_agent_cost(result)
          record_usage(agent_class, result, attempt_kind, model_reference, attempt_id:)
          result
        end
      end

      # Returns [invocation_cost, fully_priced, per_response_results].
      def record_completion_usage(agent_class, completion, attempt_kind, model_reference, attempt_id: nil)
        results = record_response_usages(agent_class, completion.provider_usages, attempt_kind, model_reference,
                                         attempt_id:)
        [*summarize_invocation_costs(results.map(&:cost), completion), results]
      end

      # Returns [invocation_cost, fully_priced]. The cost is the sum of the
      # priced responses (nil when none was priced). fully_priced is true
      # only when every provider response carried usage and every usage
      # priced; a partial sum is still returned (it is what was verifiably
      # billed) but callers must not present it as the complete invocation
      # cost.
      def summarize_invocation_costs(costs, completion)
        priced = costs.compact
        invocation_cost = priced.empty? ? nil : priced.sum
        fully_priced = completion.usage_complete && !costs.empty? && priced.length == costs.length
        [invocation_cost, fully_priced]
      end
    end
  end
end
