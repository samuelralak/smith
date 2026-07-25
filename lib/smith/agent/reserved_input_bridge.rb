# frozen_string_literal: true

module Smith
  class Agent
    module ReservedInputBridge
      private

      def partition_inputs(kwargs)
        input_values, chat_options = super
        provider = input_values[:provider]
        chat_options[:provider] = provider if provider && provider.to_sym != :unknown
        [input_values, chat_options]
      end

      def apply_configuration(chat_object, input_values:, persist_instructions:)
        super(
          chat_object,
          input_values: reserved_inputs_for(chat_object, input_values),
          persist_instructions:
        )
      end

      def reserved_inputs_for(chat_object, input_values)
        llm_chat = chat_object.respond_to?(:to_llm) ? chat_object.to_llm : chat_object
        model = llm_chat.model if llm_chat.respond_to?(:model)
        profile = resolve_profile(
          model&.id || input_values[:model_id],
          provider: actual_provider(llm_chat) || input_values[:provider]
        )
        return input_values unless profile

        input_values.merge(
          model_id: profile.model_id,
          provider: profile.provider,
          endpoint_mode: profile.endpoint_mode
        )
      end
    end
  end
end
