# frozen_string_literal: true

require "ruby_llm"

module Smith
  module Providers
    # Where batch mode meets RubyLLM: a provider's synchronous response
    # (`sync_response`), which a call reaches with the exact payload and
    # per-call headers it would post. While a batch step captures, the
    # payload is thrown out as the batch request before anything is sent;
    # while it delivers, the batch result is parsed by the provider's own
    # parser instead of a response from the wire. A call that renders
    # another request than the one sent (its digest differs: a date in its
    # prompt, data read afresh) takes the result all the same and the
    # delivery says so, unless its step declares another `on_request_change`
    # (then BatchRequestChanged, before the result is read). Only the call's
    # own provider object is affected, so any other RubyLLM call (a tool's)
    # goes over the wire as ever.
    module BatchExchange
      HELD = :smith_batch_exchange
      CAPTURED = :smith_batch_request
      private_constant :HELD

      # A capture notes its request's hold (RequestHolds), for a host's
      # budget ledger.
      Exchange = Struct.new(:provider, :result, :digest, :changed, :on_change, :hold)
      # What a provider's response parser reads.
      Response = Struct.new(:body)

      module_function

      # Runs the block with `result` (a batch result) answering its call,
      # whose request was the one with `digest`; returns the block's value
      # and whether the call rendered another request. Unless `on_change` is
      # :keep, a call that renders another request raises
      # BatchRequestChanged instead of taking the result.
      def deliver(provider, result, digest, on_change: :keep, &)
        exchange = Exchange.new(provider, result, digest, false, on_change)
        [within(exchange, &), exchange.changed]
      end

      def within(exchange)
        outer = Fiber[HELD]
        Fiber[HELD] = exchange
        yield
      ensure
        Fiber[HELD] = outer
      end

      def exchange_for(provider)
        exchange = Fiber[HELD]
        exchange if exchange&.provider.equal?(provider)
      end

      # Prepended on RubyLLM::Provider.
      module Hook
        private

        def sync_response(connection, payload, additional_headers = {})
          exchange = BatchExchange.exchange_for(self)
          return super unless exchange

          unless exchange.result
            throw(CAPTURED, Smith::Batch.request(provider: slug, params: payload, headers: additional_headers))
          end

          exchange.changed = Smith::Batch.changed?(exchange.digest, payload, additional_headers)
          raise Smith::BatchRequestChanged if exchange.changed && exchange.on_change != :keep

          parse_completion_response(Response.new(Smith::Batch.message!(exchange.result).to_h))
        end
      end
    end
  end
end

RubyLLM::Provider.prepend(Smith::Providers::BatchExchange::Hook)
