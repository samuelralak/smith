# frozen_string_literal: true

require_relative "completion_usage_recording"
require_relative "usage_entry_recording"
require_relative "usage_traces"

module Smith
  class Agent
    module UsageTracking
      include CompletionUsageRecording
      include UsageEntryRecording
      include UsageTraces

      private

      # A failed attempt's own reported usage, cache counts included, is
      # recorded, priced and settled into the budget like any billed
      # response, so its usage entry agrees with its :provider_call trace.
      def account_failed_attempt(error, model_reference, agent_class, attempt_id: nil)
        usage = ProviderUsage.from_message(error)
        return unless usage

        record_billed_usages(agent_class, [usage], :failed_attempt, model_reference, attempt_id:)
      end

      # The completed rounds of a tool loop whose attempt then failed were
      # billed: they are recorded and settled into the budget like a failed
      # attempt's usage. Returns the provider usages recorded, so the
      # attempt's trace carries the same totals its usage entries hold.
      def account_completed_prefix(agent_class, model_reference, messages, attempt_id: nil, stream: nil)
        completion = Completion.from_messages(response: nil, messages:, stream:)
        record_billed_usages(agent_class, completion.provider_usages, :partial_attempt, model_reference, attempt_id:)
        completion.provider_usages
      end

      # Usage that is billed but is not the invocation's result joins the
      # failed billable attempts, which budget settlement reads beside it.
      def record_billed_usages(agent_class, usages, attempt_kind, model_reference, attempt_id:)
        results = record_response_usages(agent_class, usages, attempt_kind, model_reference, attempt_id:)
        add_failed_agent_results(results)
      end

      # A new Array, never the one in place: a step's thread context
      # (ThreadContextSnapshot) puts back the list it started with, which
      # must not carry this step's failed attempts into the next.
      def add_failed_agent_results(results)
        Thread.current[:smith_failed_agent_results] = [*Array(Thread.current[:smith_failed_agent_results]), *results]
      end

      # Records and settles one completed attempt's usage and returns its
      # result, whether or not the result becomes the output.
      def account_attempt(agent_class, completion, model_reference, attempt_id: nil)
        model_reference = coerce_model_reference(model_reference)
        agent_result = completion_agent_result(completion, model_reference)
        Thread.current[:smith_last_agent_result] = agent_result
        emit_token_usage(agent_result)
        account_completion!(agent_class, completion, model_reference, agent_result, attempt_id)
        agent_result
      end

      # The output has been through `after_completion` (OutputIntegrity).
      def finalize_output(agent_class, agent_result)
        raise_blank_output!(agent_class, agent_result)
        agent_result
      end

      def completion_agent_result(completion, model_reference)
        Workflow::AgentResult.new(
          content: completion.content,
          input_tokens: completion.input_tokens,
          output_tokens: completion.output_tokens,
          cost: nil,
          model_used: model_reference.model_id,
          provider_used: model_reference.provider,
          **Workflow::AgentResult.usage_details(completion.usage)
        )
      end

      def raise_blank_output!(agent_class, agent_result)
        return unless blank_agent_output?(agent_result.content)

        raise Smith::BlankAgentOutputError.new(
          agent_name: agent_class.register_as,
          model_used: agent_result.model_used
        )
      end

      def blank_agent_output?(content)
        return true if content.nil?
        return content.strip.empty? if content.is_a?(String)

        false
      end

      # Records one usage entry per provider response and settles the
      # invocation's cost from the recorded per-response sum: that sum is
      # what tiered catalogs bill, so it becomes agent_result.cost (which
      # budget settlement and result surfaces read) and the recorded entries,
      # the budget ledger, and the :cost trace all agree. The trace emits
      # only for fully metered, fully priced invocations, so a partial
      # figure is never presented as the invocation cost; the partial sums
      # of cost and tokens still settle the budget because they are what
      # was verifiably billed.
      def account_completion!(agent_class, completion, model_reference, agent_result, attempt_id)
        invocation_cost, fully_priced, results = record_completion_usage(
          agent_class, completion, :completed_attempt, model_reference, attempt_id:
        )
        agent_result.cost = invocation_cost
        agent_result.metered_tokens = results.sum(&:total_tokens) unless completion.usage_complete
        return unless fully_priced

        emit_cost_trace(agent_result, invocation_cost, cache_unpriced: results.any?(&:cache_unpriced))
      end

      # Prices the result and notes whether cache tokens were priced at 0
      # for lack of a rate, which the :cost trace reports.
      def compute_agent_cost(agent_result)
        return unless agent_result.usage_known?

        usage = {
          model: agent_result.model_used, provider: agent_result.provider_used,
          input_tokens: agent_result.input_tokens, output_tokens: agent_result.output_tokens,
          cache_read_tokens: agent_result.cache_read_tokens || 0,
          cache_write_tokens: agent_result.cache_write_tokens || 0
        }
        agent_result.cost = Smith::Pricing.compute_cost(**usage, mode: agent_result.mode || :sync)
        agent_result.cache_unpriced = Smith::Pricing.cache_unpriced?(**usage.except(:output_tokens))
      end
    end
  end
end
