# frozen_string_literal: true

require "dry-struct"

require_relative "../types"
require_relative "model_reference"
require_relative "provider_usage"

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
      # The candidate's position in the model chain, the registered name of
      # the agent that made the attempt, and the provider-reported usage its
      # usage entries record (nil when the provider reported none).
      attribute :attempt_index, Types::Integer.optional.default(nil)
      attribute :agent_name, (Types::Symbol | Types::String).optional.default(nil)
      attribute :usage, Types.Instance(ProviderUsage).optional.default(nil)

      def self.success(completion:, model_reference:, **facts)
        new(completion:, model_reference:, error: nil, **facts)
      end

      def self.failure(error:, model_reference:, **facts)
        new(completion: nil, model_reference:, error:, **facts)
      end

      def success?
        error.nil?
      end
    end
  end
end
