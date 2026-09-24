# frozen_string_literal: true

require "dry-struct"

require_relative "../types"

module Smith
  class Agent
    class ProviderUsage < Dry::Struct
      attribute :input_tokens, Types::Integer
      attribute :output_tokens, Types::Integer

      def self.from_message(message)
        return unless message.respond_to?(:input_tokens) && message.respond_to?(:output_tokens)

        input_tokens = message.input_tokens
        output_tokens = message.output_tokens
        return unless input_tokens.is_a?(Integer) && output_tokens.is_a?(Integer)

        new(input_tokens:, output_tokens:)
      end

      def self.sum(usages)
        return if usages.empty?

        new(input_tokens: usages.sum(&:input_tokens), output_tokens: usages.sum(&:output_tokens))
      end

      def total_tokens
        input_tokens + output_tokens
      end
    end
  end
end
