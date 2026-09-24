# frozen_string_literal: true

module Smith
  class Agent
    module FallbackConfiguration
      attr_reader :fallback_models_block

      def fallback_models(*models, &block)
        return configure_dynamic_fallback_models(models, block) if block
        return @fallback_models_list if models.empty?

        @fallback_models_block = nil
        @fallback_models_list = qualified_fallback_references(models)
      end

      # Evaluated per invocation with the workflow context. The entries pass
      # the static form's validation and de-duplication: O(F) time and space
      # for F returned entries.
      def resolve_fallback_models(context)
        return @fallback_models_list || [].freeze unless fallback_models_block

        qualified_fallback_references([fallback_models_block.call(context)])
      end

      private

      def configure_dynamic_fallback_models(models, block)
        raise ArgumentError, "fallback_models can take model entries OR a block, not both" if models.any?

        @fallback_models_list = nil
        @fallback_models_block = block
      end

      def qualified_fallback_references(models)
        models.flatten.compact.map { qualified_fallback_reference(_1) }.uniq(&:key).freeze
      end

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
