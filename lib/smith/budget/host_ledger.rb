# frozen_string_literal: true

require_relative "amount"

module Smith
  module Budget
    # The protocol of a host's budget ledger (a workflow's `budget_ledger`),
    # and how Smith calls it.
    #
    # `reserve!(amount, key:, expires_at:)` admits a provider request's hold
    # (a Budget::Amount) when it returns true, and refuses it otherwise.
    # `reconcile!(key, amount)` records what the request spent, in place of
    # its hold if it had one: a key may be reconciled that was never held
    # (a later round of a tool loop, or a result that came for a hold that
    # expired). `release!(key)` says it spent nothing. A hold not settled by
    # `expires_at` (its process died during the request) counts for nothing
    # after it; Smith runs no timer. A key may come again after a crash: a
    # reserve of it replaces its hold, a release ends its hold, and its
    # reconcile is final (a ledger records it once). Fan-out branches call
    # the ledger from their own threads.
    #
    # A refusal raises BudgetUnavailable before the request is sent. An
    # error from building the ledger or from `reserve!` becomes
    # BudgetLedgerError (the hold, if `reserve!` took it, is released), as
    # nothing was sent. An error from `reconcile!` or `release!` is logged
    # by class and the step goes on: the money is spent, and a ledger that
    # could not record it must not cost the answer.
    module HostLedger
      METHODS = %i[reserve! reconcile! release!].freeze
      INHERITED = :smith_inherited_budget_ledger
      SCOPE_STRING_BYTES = 256
      private_constant :INHERITED, :SCOPE_STRING_BYTES

      module_function

      def check!(ledger)
        return ledger if ledger.nil? || METHODS.all? { ledger.respond_to?(_1) }

        raise WorkflowError, "a budget_ledger must respond to #{METHODS.join(", ")}"
      end

      # The run's ledger from its builder and the scope it was created with.
      def build(builder, scope)
        check!(builder.call(scope))
      rescue WorkflowError
        raise
      rescue StandardError => e
        raise BudgetLedgerError, "the budget ledger could not be built (#{e.class})"
      end

      # Admits the hold until `seconds` (Smith.config.budget_hold_ttl, plus a
      # batch's wait) from now.
      def admit!(ledger, amount, key, seconds: Smith.config.budget_hold_ttl)
        raise BudgetUnavailable unless ledger.reserve!(amount, key:, expires_at: Time.now.utc + seconds) == true
      rescue BudgetUnavailable
        raise
      rescue StandardError => e
        settle(ledger, key, nil)
        raise BudgetLedgerError, "the budget ledger could not reserve (#{e.class})"
      end

      def settle(ledger, key, amount)
        amount ? ledger.reconcile!(key, amount) : ledger.release!(key)
      rescue StandardError => e
        Smith.config.logger&.error("Smith budget ledger #{amount ? "reconcile!" : "release!"} error: #{e.class}")
        nil
      end

      # What a response's usage cost, as an Amount, priced as Smith prices
      # usage; a count that is not a non-negative Integer counts as 0.
      def amount(usage, model:, provider:, mode: :sync)
        counts = [usage.input_tokens, usage.output_tokens, usage.cache_read_tokens, usage.cache_write_tokens]
        input, output, reads, writes = counts.map { _1.is_a?(Integer) && _1.positive? ? _1 : 0 }
        Amount.new(
          input_tokens: input + reads + writes, output_tokens: output,
          cost: Pricing.compute_cost(model:, provider:, input_tokens: input, output_tokens: output,
                                     cache_read_tokens: reads, cache_write_tokens: writes, mode:)
        )
      end

      # The scope a run's ledger is built from: the values its `keys` have in
      # the run's trusted context when it is created, JSON scalars (a String
      # of at most SCOPE_STRING_BYTES bytes), kept with the run so that what
      # a step writes later never chooses another ledger.
      def scope!(keys, context, untrusted)
        keys.to_h do |key|
          raise WorkflowError, "budget_ledger scope key #{key.inspect} is untrusted" if untrusted.include?(key)

          [key, scope_value!(key, context.is_a?(Hash) ? context[key] : nil)]
        end.freeze
      end

      # A stored scope, if it names the declared keys; nil (capture it
      # again) if the declaration changed.
      def stored_scope(keys, stored)
        return unless stored.is_a?(Hash) && same_keys?(keys, stored)

        stored = stored.transform_keys(&:to_s)
        keys.to_h { |key| [key, scope_value!(key, stored[key.to_s])] }.freeze
      rescue WorkflowError
        raise SerializationError, "persisted workflow budget_ledger_scope is invalid"
      end

      def same_keys?(keys, stored) = stored.keys.map(&:to_s).sort == keys.map(&:to_s).sort

      def scope_value!(key, value)
        case value
        when nil, true, false, Integer then value
        when Float then value.finite? ? value : invalid_scope!(key)
        when String then value.bytesize <= SCOPE_STRING_BYTES ? value.dup.freeze : invalid_scope!(key)
        else invalid_scope!(key)
        end
      end

      def invalid_scope!(key)
        raise WorkflowError, "budget_ledger scope key #{key.inspect} must hold a JSON scalar " \
                             "(a String of at most #{SCOPE_STRING_BYTES} bytes)"
      end

      # A nested workflow built in the block charges `source` (the enclosing
      # run's ledger, as a callable) unless it names a ledger of its own.
      def inheriting(source)
        outer = Thread.current[INHERITED]
        Thread.current[INHERITED] = source
        yield
      ensure
        Thread.current[INHERITED] = outer
      end

      def take_inherited
        source = Thread.current[INHERITED]
        Thread.current[INHERITED] = nil
        source
      end
    end
  end
end
