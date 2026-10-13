# frozen_string_literal: true

module Smith
  class Agent
    module AttemptChat
      private

      # An attempt's chat. A streamed step's sends each request it streams
      # over the wire once: RubyLLM's HTTP retries would send it again on an
      # error, its error body already read into the first request's buffer
      # (so a refusal for want of credit reaches Smith as a bare "Invalid
      # request", never classified) or its text already streamed (the
      # retry's text would join it). Smith's fallbacks and the step's
      # retries take their place. Its chat takes a copy of the agent's config
      # (its context, or RubyLLM's) without the retries, and resolves its
      # model again as RubyLLM builds a chat with a context (the same id and
      # provider, and the agent's own assume_model_exists, so a model RubyLLM
      # knows keeps its limits), before any hold attaches to its provider. A
      # request OpenAI's Responses route sends answers whole, unstreamed,
      # and keeps the retries.
      def attempt_chat(agent_class, model_reference)
        chat = agent_class.chat(**model_reference.chat_options, **bridge_workflow_inputs(agent_class))
        return chat unless @step_stream && streams_over_the_wire?(chat)

        sent_once(chat, agent_class)
      end

      def sent_once(chat, agent_class)
        model = chat.model
        config = (agent_class.context&.config || RubyLLM.config).dup
        config.max_retries = 0
        chat.with_context(RubyLLM::Context.new(config))
        chat.with_model(model.id, provider: model.provider,
                                  assume_exists: agent_class.chat_kwargs.fetch(:assume_model_exists, false))
      end

      def streams_over_the_wire?(chat)
        return false unless chat.respond_to?(:with_context) && chat.respond_to?(:with_model)

        (chat.params[:openai_api_mode] || chat.params["openai_api_mode"]).to_s != "responses"
      end
    end
  end
end
