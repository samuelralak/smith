# frozen_string_literal: true

module Smith
  class Agent
    module FallbackConfiguration
      def fallback_models(*models)
        return @fallback_models_list if models.empty?

        entries = models.flatten.compact.map { qualified_fallback_reference(_1) }
        @fallback_models_list = entries.uniq(&:key).freeze
      end

      private

      def qualified_fallback_reference(model)
        reference = ModelReference.coerce(model)
        return reference if reference.provider

        raise Smith::WorkflowError,
              "fallback model #{reference.model_id.inspect} must include an explicit provider"
      rescue ArgumentError, Dry::Struct::Error => e
        raise Smith::WorkflowError, "invalid fallback model: #{e.message}"
      end
    end
  end
end
