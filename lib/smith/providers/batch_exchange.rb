# frozen_string_literal: true

require "ruby_llm"

module Smith
  module Providers
    # Where batch mode meets RubyLLM: a provider's synchronous response
    # (`sync_response`), which a call reaches with the exact payload and
    # per-call headers it would post. While a batch step captures, the
    # payload is thrown out as the batch request before anything is sent;
    # while it delivers, the batch result is parsed by the provider's own
    # parser instead of a response from the wire. Only the call's own
    # provider object is affected, so any other RubyLLM call (a tool's) goes
    # over the wire as ever.
    module BatchExchange
      HELD = :smith_batch_exchange
      CAPTURED = :smith_batch_request
      private_constant :HELD

      Exchange = Struct.new(:provider, :result)
      # What a provider's response parser reads.
      Response = Struct.new(:body)

      module_function

      # Runs the block with `result` (a batch result) answering its call.
      def deliver(provider, result, &) = within(Exchange.new(provider, result), &)

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

          parse_completion_response(Response.new(Smith::Batch.message!(exchange.result).to_h))
        end
      end
    end
  end
end

RubyLLM::Provider.prepend(Smith::Providers::BatchExchange::Hook)
