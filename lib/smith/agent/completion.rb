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

      def self.from_messages(response:, messages:)
        assistant_messages = Array(messages).select do |message|
          message.respond_to?(:role) && message.role.to_s == "assistant"
        end
        usage_source = assistant_messages.empty? ? [response] : assistant_messages

        provider_usages = build_provider_usages(usage_source)
        new(
          response: response,
          provider_usages:,
          usage_complete: provider_usages.length == usage_source.length
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

      def self.build_provider_usages(messages)
        messages.filter_map { |message| ProviderUsage.from_message(message) }.freeze
      end
      private_class_method :build_provider_usages
    end
  end
end
