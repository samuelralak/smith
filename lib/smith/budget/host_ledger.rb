# frozen_string_literal: true

require_relative "amount"

module Smith
  module Budget
    # The protocol of a host's budget ledger (a workflow's `budget_ledger`),
    # and how Smith calls it. `reserve!(amount, key:, expires_at:)` admits a
    # provider request's hold (a Budget::Amount) when it returns truthy, and
    # refuses it on nil or false; `reconcile!(key, amount)` records what the
    # request spent; `release!(key)` says it spent nothing. A hold not settled
    # by `expires_at` (its process died during the request, or the run never
    # resumed from its batch) counts for nothing after it: Smith runs no timer,
    # so the ledger leaves it out of what it admits. Keys are unique, and a
    # key may be settled again after a crash: a ledger settles each once.
    # A refusal raises BudgetUnavailable before the request is sent, and an
    # error from `reserve!` passes on, as nothing was sent. An error from
    # `reconcile!` or `release!` is logged by class and the step goes on: the
    # money is spent, and a ledger that could not record it must not cost the
    # answer.
    module HostLedger
      METHODS = %i[reserve! reconcile! release!].freeze

      module_function

      def check!(ledger)
        return ledger if ledger.nil? || METHODS.all? { ledger.respond_to?(_1) }

        raise WorkflowError, "a budget_ledger must respond to #{METHODS.join(", ")}"
      end

      # Admits the hold until `seconds` (Smith.config.budget_hold_ttl, plus a
      # batch's wait) from now.
      def admit!(ledger, amount, key, seconds: Smith.config.budget_hold_ttl)
        raise BudgetUnavailable unless ledger.reserve!(amount, key:, expires_at: Time.now.utc + seconds)
      end

      def settle(ledger, key, amount)
        amount ? ledger.reconcile!(key, amount) : ledger.release!(key)
      rescue StandardError => e
        Smith.config.logger&.error("Smith budget ledger #{amount ? "reconcile!" : "release!"} error: #{e.class}")
        nil
      end

      # What a response's usage cost, as an Amount, priced as Smith prices
      # usage.
      def amount(usage, model:, provider:, mode: :sync)
        reads = usage.cache_read_tokens || 0
        writes = usage.cache_write_tokens || 0
        Amount.new(
          input_tokens: usage.input_tokens + reads + writes, output_tokens: usage.output_tokens,
          cost: Pricing.compute_cost(model:, provider:, input_tokens: usage.input_tokens,
                                     output_tokens: usage.output_tokens, cache_read_tokens: reads,
                                     cache_write_tokens: writes, mode:)
        )
      end
    end
  end
end
