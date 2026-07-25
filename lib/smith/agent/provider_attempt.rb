# frozen_string_literal: true

require "dry-struct"

require_relative "../types"
require_relative "model_reference"

module Smith
  class Agent
    class ProviderAttempt < Dry::Struct
      attribute :completion, Types::Any.optional
      attribute :model_reference, Types.Instance(ModelReference)
      attribute :error, Types.Instance(StandardError).optional

      def self.success(completion:, model_reference:)
        new(completion:, model_reference:, error: nil)
      end

      def self.failure(error:, model_reference:)
        new(completion: nil, model_reference:, error:)
      end

      def success?
        error.nil?
      end
    end
  end
end
