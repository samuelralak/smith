# frozen_string_literal: true

module Smith
  class Agent
    module ChatConstruction
      def chat(**kwargs)
        kwargs, profile = prepare_input_kwargs(kwargs)

        llm_chat = install_tool_execution_context(super)
        normalize_chat(llm_chat, fallback_profile: profile)
        llm_chat
      end

      def create(**kwargs)
        kwargs, = prepare_input_kwargs(kwargs)
        prepare_persisted_chat(super, kwargs:)
      end

      def create!(**kwargs)
        kwargs, = prepare_input_kwargs(kwargs)
        prepare_persisted_chat(super, kwargs:)
      end

      def find(id, **kwargs)
        kwargs, = prepare_input_kwargs(kwargs)
        prepare_persisted_chat(super, kwargs:)
      end

      private

      def install_tool_execution_context(chat_object)
        return unless chat_object

        llm_chat = chat_object.respond_to?(:to_llm) ? chat_object.to_llm : chat_object
        Tool::ChatExecutionContext.install(llm_chat)
        chat_object
      end

      def resolve_profile(model_id, provider: nil)
        return unless model_id && defined?(Smith::Models)

        Smith::Models.find_or_infer(model_id, provider: provider)
      end

      def prepare_persisted_chat(chat_object, kwargs:)
        return unless chat_object

        install_tool_execution_context(chat_object)
        llm_chat = chat_object.respond_to?(:to_llm) ? chat_object.to_llm : chat_object
        profile = resolve_profile(
          persisted_model_id(chat_object, kwargs),
          provider: persisted_provider(chat_object, kwargs)
        )
        normalize_chat(llm_chat, fallback_profile: profile)
        chat_object
      end

      def normalize_chat(llm_chat, fallback_profile:)
        chat_model = llm_chat.model if llm_chat.respond_to?(:model)
        profile = resolve_profile(
          chat_model&.id || fallback_profile&.model_id,
          provider: actual_provider(llm_chat) || fallback_profile&.provider
        )
        Smith::Models::Normalizer.apply!(llm_chat, profile: profile) if profile
      end

      def persisted_model_id(chat_object, kwargs)
        kwargs[:model] || (chat_object.model_id if chat_object.respond_to?(:model_id)) || chat_kwargs[:model]
      end

      def persisted_provider(chat_object, kwargs)
        kwargs[:provider] || (chat_object.provider if chat_object.respond_to?(:provider)) || configured_provider(kwargs)
      end

      def configured_provider(kwargs)
        return kwargs[:provider] if kwargs.key?(:provider)
        return if kwargs.key?(:model) && kwargs[:model].to_s != chat_kwargs[:model].to_s

        chat_kwargs[:provider]
      end

      def actual_provider(llm_chat)
        provider = llm_chat.instance_variable_get(:@provider)
        provider.slug if provider.respond_to?(:slug)
      end

      def prepare_input_kwargs(kwargs)
        model_id = kwargs[:model] || chat_kwargs[:model]
        provider = configured_provider(kwargs)
        profile = resolve_profile(model_id, provider:)
        prepared = nil_fill_declared_inputs(inject_reserved_inputs(kwargs, profile, provider:))
        [prepared, profile]
      end

      def inject_reserved_inputs(kwargs, profile, provider:)
        return kwargs unless profile

        {
          model_id: profile.model_id,
          provider:,
          endpoint_mode: profile.endpoint_mode
        }.merge(kwargs)
      end

      def nil_fill_declared_inputs(kwargs)
        inputs.each_with_object(kwargs.dup) do |name, result|
          result[name] = nil unless result.key?(name)
        end
      end
    end
  end
end
