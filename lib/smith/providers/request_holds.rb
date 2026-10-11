# frozen_string_literal: true

require "ruby_llm"

module Smith
  module Providers
    # Where a host's budget ledger (a workflow's `budget_ledger`) meets
    # RubyLLM: each request a step's call makes over the wire (each round of
    # a tool loop, each fallback model, each follow-up, streamed or not, and
    # OpenAI's Responses route, which never reaches the base class) goes
    # through `Provider#complete`. A call's first request is held before
    # anything is sent. A later round of a tool loop continues a call whose
    # tools already ran: it is held only when its step can pause for budget
    # (`pausable`), and otherwise goes on, reconciled all the same. Each
    # request is then reconciled with what it spent (its usage; its hold
    # when it answered without usage or its stream failed part way) or, if
    # it failed before anything came back, its hold is released. Only the
    # call's own provider object is held, so a tool's own RubyLLM call is
    # not. While a batch step captures its request, the hold is noted on the
    # capture instead, for the batch to reserve.
    module RequestHolds
      HELD = :smith_request_holds
      private_constant :HELD

      Holder = Struct.new(:provider, :ledger, :attempt_id, :pausable, :rounds, :busy)
      # Whether a streamed request's response began.
      Stream = Struct.new(:started)

      module_function

      # Runs the block with the provider's requests held on `ledger`, keyed
      # "<attempt_id>:<round>".
      def within(provider, ledger, attempt_id, pausable: false)
        outer = Fiber[HELD]
        Fiber[HELD] = Holder.new(provider, ledger, attempt_id, pausable, 0, false)
        yield Fiber[HELD]
      ensure
        Fiber[HELD] = outer
      end

      # The holder of a request the provider is about to make, unless one is
      # under way (the base class's hook inside OpenAI's).
      def holder_for(provider)
        holder = Fiber[HELD]
        holder if holder&.provider.equal?(provider) && !holder.busy
      end

      def hold(provider, args, kwargs, mode: :sync)
        Budget::RequestHold.for_request(
          provider: provider.slug, model: kwargs.fetch(:model), messages: args.first, tools: kwargs[:tools],
          schema: kwargs[:schema], params: kwargs[:params], mode:
        )
      end

      # The request (`request`: the provider's own `complete`), held.
      def complete(provider, args, kwargs, block, &request)
        exchange = BatchExchange.exchange_for(provider)
        return capture(provider, exchange, args, kwargs, block, &request) if exchange

        ResponseMemo.round(provider, args.first) { send_held(provider, args, kwargs, block, &request) }
      end

      def send_held(provider, args, kwargs, block, &request)
        holder = holder_for(provider)
        return request.call(*args, **kwargs, &block) unless holder

        held(holder, hold(provider, args, kwargs), kwargs.fetch(:model).id) do |stream|
          next request.call(*args, **kwargs) unless block

          request.call(*args, **kwargs) do |chunk|
            stream.started = true
            block.call(chunk)
          end
        end
      end

      def capture(provider, exchange, args, kwargs, block, &request)
        exchange.hold ||= hold(provider, args, kwargs, mode: :batch) if exchange.holding && exchange.result.nil?
        request.call(*args, **kwargs, &block)
      end

      def held(holder, amount, model_id)
        key, reserved = open_round(holder, amount)
        stream = Stream.new(false)
        begin
          message = busy(holder) { yield(stream) }
        rescue Exception => e # rubocop:disable Lint/RescueException -- an interrupted request settles too
          settle_failed(holder, key, spent(holder.provider, model_id, e) || (amount if stream.started), reserved)
          raise
        end
        Budget::HostLedger.settle(holder.ledger, key, spent(holder.provider, model_id, message) || amount)
        message
      end

      # The request's key and whether it is held: a call's first request, or
      # any round of a step that can pause for budget.
      def open_round(holder, amount)
        holder.rounds += 1
        key = "#{holder.attempt_id}:#{holder.rounds}"
        reserved = holder.rounds == 1 || holder.pausable
        Budget::HostLedger.admit!(holder.ledger, amount, key) if reserved
        [key, reserved]
      end

      def busy(holder)
        holder.busy = true
        yield
      ensure
        holder.busy = false
      end

      # A failed request reconciles what it spent; a held one that spent
      # nothing is released, an unheld one settles nothing.
      def settle_failed(holder, key, spent, reserved)
        Budget::HostLedger.settle(holder.ledger, key, spent) if spent || reserved
      end

      # What a request spent, from its reply (or the error that reported
      # usage), priced for the request's model; nil when it reported none.
      def spent(provider, model_id, reply)
        usage = Agent::ProviderUsage.from_message(reply)
        Budget::HostLedger.amount(usage, model: model_id, provider: provider.slug) if usage
      end

      # Prepended on RubyLLM::Provider, and on RubyLLM::Providers::OpenAI
      # outside Smith's Responses routing.
      module Hook
        def complete(*args, **kwargs, &block)
          RequestHolds.complete(self, args, kwargs, block) do |*sent, **options, &chunks|
            super(*sent, **options, &chunks)
          end
        end
      end
    end
  end
end

RubyLLM::Provider.prepend(Smith::Providers::RequestHolds::Hook)
RubyLLM::Providers::OpenAI.prepend(Smith::Providers::RequestHolds::Hook)
