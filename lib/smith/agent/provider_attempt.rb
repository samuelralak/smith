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
      # One attempt = one chat completion (including any provider tool loop).
      # `attempt_id` joins the attempt's usage entries to its single measured
      # duration; `duration_ms` is nil when the attempt failed before the
      # completion call started.
      attribute :attempt_id, Types::String.optional.default(nil)
      attribute :duration_ms, Types::Integer.optional.default(nil)

      def self.success(completion:, model_reference:, attempt_id: nil, duration_ms: nil)
        new(completion:, model_reference:, error: nil, attempt_id:, duration_ms:)
      end

      def self.failure(error:, model_reference:, attempt_id: nil, duration_ms: nil)
        new(completion: nil, model_reference:, error:, attempt_id:, duration_ms:)
      end

      def success?
        error.nil?
      end
    end
  end
end
