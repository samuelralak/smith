# frozen_string_literal: true

require "ruby_llm"

require_relative "response_facts"

module Smith
  module Providers
    # The stop reason and message id of each response of a streamed call. A
    # streamed RubyLLM message keeps no raw body for ResponseFacts to read,
    # so the facts are read from the provider's stream events as RubyLLM
    # turns them into chunks, each event recognized by its own markers:
    #
    #   Anthropic        "message_start" message.id; "message_delta" delta.stop_reason
    #   OpenAI and kin   "choices" => [...]: id, choices[0].finish_reason, delta.refusal
    #   Gemini           candidates[0].finishReason, responseId; promptFeedback.blockReason
    #   Bedrock          stopReason, or messageStop.stopReason
    #
    # Only the call's own provider object is read (a tool's own RubyLLM call
    # streams through another), and each provider request (a round of a
    # tool loop) keeps facts of its own. The collection lives in fiber
    # storage, which fibers and threads started inside the call inherit.
    # Reading never raises.
    #
    # A streamed reply without a stop reason did not end as the provider
    # ends a reply: it counts as cut off, as LIMIT_REACHED when its output
    # tokens reached the request's limit, else as INCOMPLETE.
    module StreamFacts
      HELD = :smith_stream_facts
      LIMIT_REACHED = "output_limit_reached"
      INCOMPLETE = "stream_incomplete"
      MARK = :@smith_stream_facts_observer
      private_constant :HELD, :MARK

      # The streams of one call: its provider (nil reads any) and the facts
      # of each of its requests.
      class Collection
        attr_reader :rounds

        def initialize(provider)
          @provider = provider
          @rounds = []
        end

        def owns?(provider) = @provider.nil? || provider.equal?(@provider)

        def open_round = @rounds << {}

        def current
          open_round if @rounds.empty?
          @rounds.last
        end

        # Each round's facts, bounded.
        def facts
          @rounds.map do |round|
            { stop_reason: ResponseFacts.bounded(round[:stop_reason]),
              provider_message_id: ResponseFacts.bounded(round[:provider_message_id]) }.compact
          end
        end
      end

      module_function

      # Runs the block, given the collection, collecting the facts of the
      # streams `provider` reads; returns them, one bounded Hash per round.
      def collect(provider)
        outer = Fiber[HELD]
        collection = Fiber[HELD] = Collection.new(provider)
        yield collection
        collection.facts
      ensure
        Fiber[HELD] = outer
      end

      # The facts of each response of a streamed call, in order: each
      # round's over its raw body's, the last settled. Rounds and responses
      # pair up in order; a round past the last response (a request that
      # failed) has none.
      def per_message(messages, rounds, output_limit)
        missing = messages.length - rounds.length
        aligned = missing.positive? ? [*Array.new(missing, {}), *rounds] : rounds.first(messages.length)
        facts = messages.zip(aligned).map { |message, round| ResponseFacts.from_message(message).merge(round) }
        facts[-1] = settle(messages.last, aligned.last, output_limit)
        facts
      end

      # A streamed response's facts: its stream's, over its raw body's (a
      # path that does not stream keeps one); without a stop reason,
      # LIMIT_REACHED or INCOMPLETE.
      def settle(message, collected, output_limit)
        facts = ResponseFacts.from_message(message).merge(collected)
        return facts if facts[:stop_reason]

        tokens = message.output_tokens if message.respond_to?(:output_tokens)
        reached = output_limit.is_a?(Integer) && tokens.is_a?(Integer) && tokens >= output_limit
        facts.merge(stop_reason: reached ? LIMIT_REACHED : INCOMPLETE)
      end

      # A request of the collecting call begins (RoundObserver).
      def round(provider)
        collection = Fiber[HELD]
        collection.open_round if collection&.owns?(provider)
      end

      def observe(provider, data)
        collection = Fiber[HELD]
        record(collection.current, data) if collection&.owns?(provider) && data.is_a?(Hash)
      rescue StandardError
        nil
      end

      def record(facts, data)
        if data["type"].is_a?(String) then anthropic(facts, data)
        elsif data["choices"].is_a?(Array) then openai(facts, data)
        elsif data.key?("candidates") || data.key?("promptFeedback") then gemini(facts, data)
        else bedrock(facts, data)
        end
      end

      def anthropic(facts, data)
        case data["type"]
        when "message_start"
          facts.delete(:stop_reason)
          facts[:provider_message_id] = data.dig("message", "id")
        when "message_delta" then facts[:stop_reason] = data.dig("delta", "stop_reason") || facts[:stop_reason]
        end
      end

      # A refusal streams as `delta.refusal` text before the finish reason.
      def openai(facts, data)
        facts[:provider_message_id] = data["id"] if data["id"]
        choice = ResponseFacts.first_entry(data["choices"])
        return unless choice

        facts[:refused] = true if ResponseFacts.chat_refusal?("message" => choice["delta"])
        reason = choice["finish_reason"]
        facts[:stop_reason] = facts[:refused] ? ResponseFacts::REFUSAL : reason if reason
      end

      def gemini(facts, data)
        facts[:provider_message_id] = data["responseId"] if data["responseId"]
        candidate = ResponseFacts.first_entry(data["candidates"])
        blocked = ResponseFacts::PROMPT_BLOCKED if data.dig("promptFeedback", "blockReason").is_a?(String)
        reason = candidate ? candidate["finishReason"] : blocked
        facts[:stop_reason] = reason if reason
      end

      def bedrock(facts, data)
        reason = data["stopReason"] || data.dig("messageStop", "stopReason")
        facts[:stop_reason] = reason if reason
      end

      # Prepended once on each of RubyLLM's streaming modules, with the
      # visibility that module gives `build_chunk`: every event a provider
      # turns into a chunk is read first.
      def install(streaming)
        return if streaming.ancestors.any? { observer?(_1) }

        observer = Module.new do
          define_method(:build_chunk) do |data|
            StreamFacts.observe(self, data)
            super(data)
          end
        end
        observer.instance_variable_set(MARK, streaming.name)
        observer.send(:private, :build_chunk) if streaming.private_method_defined?(:build_chunk)
        streaming.prepend(observer)
      end

      def observer?(mod) = mod.instance_variable_defined?(MARK)

      # Prepended on RubyLLM::Provider: each streamed request opens a round.
      module RoundObserver
        def complete(*args, **kwargs, &block)
          StreamFacts.round(self) if block
          super
        end
      end
    end
  end
end

# Installed at gem-require; the subclasses of these providers (DeepSeek,
# Mistral, xAI, Vertex AI and other OpenAI- or Gemini-compatible ones)
# inherit it.
[
  RubyLLM::Providers::Anthropic::Streaming, RubyLLM::Providers::OpenAI::Streaming,
  RubyLLM::Providers::Gemini::Streaming, RubyLLM::Providers::OpenRouter::Streaming,
  RubyLLM::Providers::Bedrock::Streaming
].each { |streaming| Smith::Providers::StreamFacts.install(streaming) }
RubyLLM::Provider.prepend(Smith::Providers::StreamFacts::RoundObserver)
