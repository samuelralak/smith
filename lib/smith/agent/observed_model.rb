# frozen_string_literal: true

module Smith
  class Agent
    # The model a chat actually holds (after RubyLLM resolved it), else the
    # reference the attempt was made with.
    module ObservedModel
      private

      def observed_model_reference(chat, fallback:)
        model = observable_model(chat)
        return fallback unless model.respond_to?(:id) && !model.id.to_s.empty?

        ModelReference.coerce(model.id, provider: observed_provider(model, fallback))
      rescue StandardError
        fallback
      end

      def observable_model(chat)
        resolved_chat = chat.respond_to?(:to_llm) ? chat.to_llm : chat
        resolved_chat.model if resolved_chat.respond_to?(:model)
      end

      def observed_provider(model, fallback)
        model.respond_to?(:provider) && !model.provider.to_s.empty? ? model.provider : fallback.provider
      end
    end
  end
end
