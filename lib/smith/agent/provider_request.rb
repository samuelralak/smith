# frozen_string_literal: true

module Smith
  class Agent
    # What one provider call asks for beyond its messages: the output schema
    # as the provider takes it, and a larger output limit when a cut-off
    # response is retried.
    module ProviderRequest
      Shape = Data.define(:output_schema, :output_limit)

      private

      def shaped_chat(chat, model_reference, shape)
        provider = observed_model_reference(chat, fallback: model_reference).provider
        chat = with_output_limit(chat, provider, shape.output_limit) if shape.output_limit
        shape.output_schema ? chat.with_schema(provider_output_schema(shape.output_schema, provider)) : chat
      end

      def with_output_limit(chat, provider, limit)
        return chat unless chat.respond_to?(:with_params)

        params = (chat.params if chat.respond_to?(:params)) || {}
        chat.with_params(**::RubyLLM::Utils.deep_merge(params, Providers::OutputLimit.params(provider, params, limit)))
      end

      # For Anthropic without the constraints it rejects (SchemaConstraints);
      # unchanged otherwise.
      def provider_output_schema(output_schema, provider)
        return output_schema unless provider.to_s == "anthropic"

        payload = Providers::SchemaConstraints.json_schema(output_schema)
        payload ? Providers::SchemaConstraints.for_provider(payload, provider) : output_schema
      end
    end
  end
end
