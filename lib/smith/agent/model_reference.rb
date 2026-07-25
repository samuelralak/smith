# frozen_string_literal: true

require "dry-struct"
require "ruby_llm"

require_relative "../types"

module Smith
  class Agent < RubyLLM::Agent
    class ModelReference < Dry::Struct
      ModelId = Types::String.constructor do |value|
        normalized = value.to_s.dup
        raise ArgumentError, "model id must not be blank" if normalized.empty?

        normalized.freeze
      end
      Provider = Types::Symbol.optional.constructor { |value| value&.to_sym }

      private_constant :ModelId, :Provider

      attribute :model_id, ModelId
      attribute :provider, Provider

      def initialize(attributes)
        super
        freeze
      end

      def self.coerce(value, provider: nil)
        return value if value.is_a?(self)
        return from_hash(value) if value.is_a?(Hash)
        return parse(value) if provider.nil? && value.is_a?(String) && value.include?("/")

        new(model_id: value, provider:)
      end

      def self.from_hash(value)
        attributes = value.transform_keys(&:to_sym)
        new(model_id: attributes[:model_id] || attributes[:model], provider: attributes[:provider])
      end
      private_class_method :from_hash

      # Inverse of #to_s: the first slash separates provider from model,
      # so a reference whose model id itself contains slashes round-trips
      # ("openrouter/openai/gpt-5" -> provider :openrouter,
      # model "openai/gpt-5"). An explicit `provider:` keyword keeps the
      # string literal and is never re-split.
      def self.parse(value)
        provider, model_id = value.split("/", 2)
        raise ArgumentError, "provider segment in #{value.inspect} must not be blank" if provider.empty?

        new(model_id:, provider:)
      end

      def key
        [provider, model_id].freeze
      end

      # True when the two references can address the same physical model:
      # an unqualified reference delegates provider selection to RubyLLM,
      # so it can resolve to any provider serving the same model id.
      def same_candidate?(other)
        model_id == other.model_id &&
          (provider.nil? || other.provider.nil? || provider == other.provider)
      end

      def chat_options
        { model: model_id, provider: }.compact.freeze
      end

      def to_s
        provider ? "#{provider}/#{model_id}" : model_id
      end
    end
  end
end
