# frozen_string_literal: true

module Smith
  class Agent
    # What one provider call asks for beyond its messages: the output schema
    # as the provider takes it, the agent's output limit under the name an
    # OpenAI model that reasons takes, a larger one when a cut-off response
    # is retried, and Anthropic's automatic prompt cache when the agent asks
    # for it (Agent.prompt_cache) and the call goes over the wire: a batch
    # request is one turn read once, which a cache write only makes dearer.
    module ProviderRequest
      Shape = Data.define(:output_schema, :output_limit, :prompt_cache)

      private

      def shaped_chat(chat, model_reference, shape)
        observed = observed_model_reference(chat, fallback: model_reference)
        provider = observed.provider
        chat = named_output_limit(chat, observed)
        chat = with_output_limit(chat, provider, shape.output_limit) if shape.output_limit
        chat = with_automatic_cache(chat) if automatic_cache?(shape, provider)
        shape.output_schema ? chat.with_schema(provider_output_schema(shape.output_schema, provider)) : chat
      end

      # Whether the call carries Anthropic's automatic prompt cache, as the
      # breakpoints are counted (ContentParts) and the request is shaped.
      def automatic_cache?(shape, provider)
        shape.prompt_cache == :automatic && anthropic?(provider) && !@batch_capturing
      end

      def with_automatic_cache(chat)
        return chat unless chat.respond_to?(:with_params)

        params = (chat.params if chat.respond_to?(:params)) || {}
        chat.with_params(**::RubyLLM::Utils.deep_merge(params, { cache_control: { type: "ephemeral" } }))
      end

      def named_output_limit(chat, observed)
        return chat unless chat.respond_to?(:with_params) && chat.respond_to?(:params) && chat.params.is_a?(Hash)

        chat.with_params(**Providers::OutputLimit.named(observed.provider, chat.params, observed))
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
