# frozen_string_literal: true

require "dry-struct"
require_relative "../types"
require_relative "provider_usage"

module Smith
  class Agent
    class Completion < Dry::Struct
      attribute :response, Types::Any
      attribute :provider_usages, Types::Array.of(Types.Instance(ProviderUsage))
      attribute :usage_complete, Types::Bool
      # The stop reason and message id of the last provider response,
      # whether or not that response reported usage.
      attribute :response_facts, Types::Hash.default({}.freeze)

      # `stream` is set for a streamed call: the facts of each of its
      # requests, read from the stream, and the request's output limit
      # (Providers::StreamFacts). Each response's usage carries its facts and
      # `mode: :stream`. `mode` marks another call's usage (:batch).
      def self.from_messages(response:, messages:, stream: nil, mode: nil)
        assistant_messages = Array(messages).select do |message|
          message.respond_to?(:role) && message.role.to_s == "assistant"
        end
        usage_source = assistant_messages.empty? ? [response] : assistant_messages
        facts = response_facts(usage_source, stream)

        provider_usages = build_provider_usages(usage_source, stream && facts, mode)
        new(
          response: response,
          provider_usages:,
          usage_complete: provider_usages.length == usage_source.length,
          response_facts: facts.last
        )
      end

      def content
        response.content if response.respond_to?(:content)
      end

      def input_tokens
        provider_usages.sum(&:input_tokens) if usage_complete
      end

      def output_tokens
        provider_usages.sum(&:output_tokens) if usage_complete
      end

      # The whole completion's usage, cache and thinking counts and the
      # final response's stop reason included; nil unless every response
      # reported usage.
      def usage
        ProviderUsage.sum(provider_usages) if usage_complete
      end

      def self.response_facts(messages, stream)
        return messages.map { Providers::ResponseFacts.from_message(_1) } unless stream

        Providers::StreamFacts.per_message(messages, stream.fetch(:rounds), stream.fetch(:output_limit))
      end

      def self.build_provider_usages(messages, streamed_facts, mode)
        messages.each_with_index.filter_map do |message, index|
          usage = ProviderUsage.from_message(message)
          usage = usage.streamed(streamed_facts[index]) if streamed_facts && usage
          mode && usage ? usage.new(mode:) : usage
        end.freeze
      end
      private_class_method :response_facts, :build_provider_usages
    end
  end
end
