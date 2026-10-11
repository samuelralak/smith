# frozen_string_literal: true

module Smith
  class Workflow
    # A batch step's requests on a host's budget ledger (`budget_ledger`,
    # Budget::HostLedger): each is held when captured, under its custom_id,
    # and settled when its result comes (BatchWait).
    module BatchHolds
      private

      # A host's budget ledger admits each request's hold (priced at the
      # batch discount) under its custom_id, inside the attempt, so a durable
      # `retry_on Smith::BudgetUnavailable` can wait for budget. A refusal,
      # or the step ending before the requests are queued, releases the
      # holds taken; queued, they are settled when the results come.
      def hold_batch!(token, holds)
        ledger = @step_budget_ledger
        return unless ledger

        release_batch_holds
        @batch_holds = []
        seconds = BatchExecution::WAIT_SECONDS + Smith.config.budget_hold_ttl
        holds.each do |branch_key, amount|
          key = Batch.custom_id(token, branch_key)
          Budget::HostLedger.admit!(ledger, amount, key, seconds:)
          @batch_holds << key
        end
      rescue StandardError
        release_batch_holds
        raise
      end

      def release_batch_holds
        keys = @batch_holds
        @batch_holds = nil
        keys&.each { Budget::HostLedger.settle(@step_budget_ledger, _1, nil) }
      end

      # Each result settles the hold its request took on a host's budget
      # ledger (BatchExecution), taken by a call or not: a succeeded one
      # reconciles what it cost, any other (or a wait that expired) releases.
      def settle_batch_holds(transition, token, entries)
        ledger = @step_budget_ledger
        return unless ledger

        entries.each do |branch_key, entry|
          spent = batch_spent(transition, branch_key, entry.result)
          Budget::HostLedger.settle(ledger, Batch.custom_id(token, branch_key), spent)
        end
      end

      def batch_spent(transition, branch_key, result)
        return unless result["type"] == "succeeded"

        usage = batch_reply_usage(result.fetch("message"))
        model = batch_agent_class(transition, branch_key).chat_kwargs[:model] || result.dig("message", "model")
        Budget::HostLedger.amount(usage, model:, provider: "anthropic", mode: :batch) if usage
      end
    end
  end
end
