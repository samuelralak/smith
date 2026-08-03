# frozen_string_literal: true

module Smith
  class Agent
    # Trace emission for a completed agent invocation's usage facts, kept
    # apart from the accounting itself (UsageTracking) so recording rows and
    # emitting observability stay separate concerns.
    module UsageTraces
      private

      def emit_token_usage(agent_result)
        return unless agent_result.usage_known?

        Smith::Trace.record(
          type: :token_usage,
          data: {
            input_tokens: agent_result.input_tokens,
            output_tokens: agent_result.output_tokens,
            model: agent_result.model_used,
            provider: agent_result.provider_used
          }.compact
        )
      end

      # One :cost trace per completed agent invocation. The cost is the sum
      # of the invocation's per-response entry costs (what tiered catalogs
      # actually bill), never the aggregate token totals priced as one call.
      # Token counts remain the invocation aggregates. Billed failed and
      # partial attempts appear only in usage entries, so summing :cost
      # traces is not a spend total. Unpriced usage emits nothing, and the
      # caller gates out partially metered or partially priced invocations
      # so an incomplete figure is never presented as the invocation cost.
      def emit_cost_trace(agent_result, invocation_cost)
        return if invocation_cost.nil?

        Smith::Trace.record(
          type: :cost,
          data: {
            cost: invocation_cost,
            model: agent_result.model_used,
            provider: agent_result.provider_used,
            input_tokens: agent_result.input_tokens,
            output_tokens: agent_result.output_tokens
          }.compact
        )
      end
    end
  end
end
