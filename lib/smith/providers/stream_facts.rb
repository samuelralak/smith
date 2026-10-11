# frozen_string_literal: true

require "ruby_llm"

require_relative "response_facts"

module Smith
  module Providers
    # The stop reason and message id of a streamed reply. A streamed
    # RubyLLM message keeps no raw body for ResponseFacts to read, so the
    # facts are read from the provider's stream events as RubyLLM turns
    # them into chunks (Observer, prepended on RubyLLM's streaming
    # modules), each event recognized by its own markers:
    #
    #   Anthropic        "message_start" message.id; "message_delta" delta.stop_reason
    #   OpenAI and kin   "choices" => [...]: id, choices[0].finish_reason, delta.refusal
    #   Gemini           candidates[0].finishReason, responseId; promptFeedback.blockReason
    #   Bedrock          stopReason, or messageStop.stopReason
    #
    # A reply of several rounds (tool calls) keeps the last round's facts.
    # Reading never raises. A streamed reply whose stop reason was not read
    # is checked by its usage instead: output tokens at the request's limit
    # count as cut off (LIMIT_REACHED).
    module StreamFacts
      HELD = :smith_stream_facts
      LIMIT_REACHED = "output_limit_reached"
      private_constant :HELD

      module_function

      # Runs the block collecting the facts of the streams it reads, and
      # returns them (bounded Strings, absent when not seen).
      def collect
        outer = Thread.current[HELD]
        facts = Thread.current[HELD] = {}
        yield
        { stop_reason: ResponseFacts.bounded(facts[:stop_reason]),
          provider_message_id: ResponseFacts.bounded(facts[:provider_message_id]) }.compact
      ensure
        Thread.current[HELD] = outer
      end

      # The facts of a streamed call's last response: those read from its
      # stream, over those of its raw body (a path that does not stream
      # keeps one); without a stop reason, LIMIT_REACHED when its output
      # tokens reached `output_limit`.
      def settle(message, collected, output_limit)
        facts = ResponseFacts.from_message(message).merge(collected)
        return facts if facts[:stop_reason] || !output_limit.is_a?(Integer)

        tokens = message.output_tokens if message.respond_to?(:output_tokens)
        tokens.is_a?(Integer) && tokens >= output_limit ? facts.merge(stop_reason: LIMIT_REACHED) : facts
      end

      def observe(data)
        facts = Thread.current[HELD]
        record(facts, data) if facts && data.is_a?(Hash)
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

      # Prepended on RubyLLM's streaming modules: every event the provider
      # turns into a chunk is read first.
      module Observer
        private

        def build_chunk(data)
          StreamFacts.observe(data)
          super
        end
      end
    end
  end
end

# Installed at gem-require (prepending a module twice changes nothing); the
# subclasses of these providers (DeepSeek, Mistral, xAI, Vertex AI and other
# OpenAI- or Gemini-compatible ones) inherit it.
[
  RubyLLM::Providers::Anthropic::Streaming, RubyLLM::Providers::OpenAI::Streaming,
  RubyLLM::Providers::Gemini::Streaming, RubyLLM::Providers::OpenRouter::Streaming,
  RubyLLM::Providers::Bedrock::Streaming
].each { |streaming| streaming.prepend(Smith::Providers::StreamFacts::Observer) }
