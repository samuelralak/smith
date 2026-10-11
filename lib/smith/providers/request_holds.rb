# frozen_string_literal: true

require "ruby_llm"

module Smith
  module Providers
    # Where a host's budget ledger (a workflow's `budget_ledger`) meets
    # RubyLLM: each request a step's call makes over the wire (each round of
    # a tool loop, each fallback model, each follow-up) goes through
    # `Provider#complete`, which asks the ledger to admit its hold
    # (Budget::RequestHold) before anything is sent, then reconciles what the
    # request spent, or releases the hold when it failed without reporting
    # usage. Only the call's own provider object is held, so a tool's own
    # RubyLLM call is not. While a batch step captures its request, the hold
    # is noted on the capture instead, for the batch to reserve.
    module RequestHolds
      HELD = :smith_request_holds
      private_constant :HELD

      Holder = Struct.new(:provider, :ledger, :attempt_id, :rounds)

      module_function

      # Runs the block with the provider's requests held on `ledger`, keyed
      # "<attempt_id>:<round>".
      def within(provider, ledger, attempt_id)
        outer = Fiber[HELD]
        Fiber[HELD] = Holder.new(provider, ledger, attempt_id, 0)
        yield
      ensure
        Fiber[HELD] = outer
      end

      def holder_for(provider)
        holder = Fiber[HELD]
        holder if holder&.provider.equal?(provider)
      end

      def hold(provider, args, kwargs, mode: :sync)
        Budget::RequestHold.for_request(
          provider: provider.slug, model: kwargs.fetch(:model), messages: args.first, tools: kwargs[:tools],
          schema: kwargs[:schema], params: kwargs[:params], mode:
        )
      end

      def held(holder, amount, model_id)
        holder.rounds += 1
        key = "#{holder.attempt_id}:#{holder.rounds}"
        Budget::HostLedger.admit!(holder.ledger, amount, key)
        begin
          message = yield
        rescue Exception => e # rubocop:disable Lint/RescueException -- an interrupted request settles too
          Budget::HostLedger.settle(holder.ledger, key, spent(holder.provider, model_id, e))
          raise
        end
        Budget::HostLedger.settle(holder.ledger, key, spent(holder.provider, model_id, message))
        message
      end

      # What a request spent, from its reply (or the error that reported
      # usage), priced for the request's model; nil when it reported none.
      def spent(provider, model_id, reply)
        usage = Agent::ProviderUsage.from_message(reply)
        Budget::HostLedger.amount(usage, model: model_id, provider: provider.slug) if usage
      end

      # Prepended on RubyLLM::Provider.
      module Hook
        def complete(*args, **kwargs, &)
          exchange = BatchExchange.exchange_for(self)
          if exchange
            exchange.hold = RequestHolds.hold(self, args, kwargs, mode: :batch) unless exchange.result
            return super
          end

          holder = RequestHolds.holder_for(self)
          return super unless holder

          RequestHolds.held(holder, RequestHolds.hold(self, args, kwargs), kwargs.fetch(:model).id) { super }
        end
      end
    end
  end
end

RubyLLM::Provider.prepend(Smith::Providers::RequestHolds::Hook)
