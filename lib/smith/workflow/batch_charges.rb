# frozen_string_literal: true

module Smith
  class Workflow
    # What batch results cost (BatchWait). A call whose result has come is
    # reserved for whatever the budget has left, never refused, as the money
    # is spent; a succeeded result no call took is recorded as a billed
    # response of its branch's agent (`:failed_attempt`, `mode: :batch`) and
    # charged to the run's budget.
    module BatchCharges
      private

      def reserve_estimates!(ledger, estimates)
        return super unless batch_result_due?

        Thread.current[:smith_call_reservation] = ledger.reserve_spent!(estimates)
      end

      def charge_untaken_batch_results(transition)
        @batch_delivery.untaken.each do |branch_key, entry|
          next unless entry.result["type"] == "succeeded"

          Attribution.with(branch_key:) do
            charge_batch_result(batch_agent_class(transition, branch_key), entry.result.fetch("message"))
          end
        end
      end

      def batch_agent_class(transition, branch_key)
        return resolve_agent_class(transition) unless branch_key

        resolve_fanout_agent_class(transition, transition.fanout_config.fetch(:branches).fetch(branch_key))
      end

      def charge_batch_result(agent_class, message)
        usage = batch_reply_usage(message)
        return unless usage

        model = Agent::ModelReference.new(model_id: batch_model_id(agent_class, message), provider: "anthropic")
        record_billed_usages(agent_class, [usage], :failed_attempt, model, attempt_id: nil)
        settle_spent_batch_charges
      end

      # The id a call of the agent prices its usage under, as RubyLLM
      # resolves the agent's model (an alias to its dated id), else the
      # result's own (a model given by a block).
      def batch_model_id(agent_class, message)
        kwargs = agent_class.chat_kwargs
        return message["model"] unless kwargs[:model]

        RubyLLM::Models.resolve(kwargs[:model], provider: kwargs[:provider],
                                                assume_exists: kwargs[:assume_model_exists] || false).first.id
      rescue StandardError
        kwargs[:model]
      end

      # A result's usage, as the provider's own parser reads its message.
      def batch_reply_usage(message)
        reply = RubyLLM::Providers::Anthropic.new(RubyLLM.config)
                                             .send(:parse_completion_response,
                                                   Providers::BatchExchange::Response.new(message.to_h))
        Agent::ProviderUsage.from_message(reply)&.new(mode: :batch)
      end

      def settle_spent_batch_charges
        ledger = effective_call_ledger
        return clear_failed_billable_attempts unless ledger

        reconcile_branch_budget(ledger, ledger.reserve_spent!(ledger.limits.keys.to_h { [_1, 0] }))
        clear_failed_billable_attempts
      end
    end
  end
end
