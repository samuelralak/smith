# frozen_string_literal: true

module Smith
  class Agent
    # The provider calls of a streamed step (Smith::Streaming): before a
    # call that replaces an earlier one, the earlier call's text is
    # withdrawn; each call is announced and its text chunks sent. The stop
    # reason is read from the stream (Providers::StreamFacts), as a
    # streamed reply keeps no raw body.
    module ProviderStreaming
      private

      # Withdraws the text a streamed step sent, for `reason`, when a call
      # is about to replace it.
      def withdraw_streamed(reason) = @step_stream&.withdraw(reason)

      # The chat's reply and, for a streamed step, what Completion needs to
      # read its facts. The stream's collection goes into `collected` too,
      # for the facts of a call that fails part way.
      def complete_chat(chat, model_reference, collected)
        stream = @step_stream
        return [chat.complete, nil] unless stream

        stream.start(attempt: @step_attempt, model: model_reference.model_id, provider: model_reference.provider&.to_s)
        response, rounds = streamed_completion(chat, stream, collected)
        [response, { rounds:, output_limit: request_output_limit(chat, model_reference) }]
      end

      # The chat's reply, its text sent as it comes (without <think> text),
      # and the facts of each of its requests.
      def streamed_completion(chat, stream, collected)
        response = nil
        thinking = Streaming::ThinkTags.new
        rounds = Providers::StreamFacts.collect(chat_provider(chat)) do |collection|
          collected << collection
          response = chat.complete { |chunk| stream.delta(thinking.strip(chunk.content, collection.rounds.length)) }
        end
        [response, rounds]
      end

      # The facts of a streamed call that failed, if it streamed.
      def streamed_rounds(collected) = collected.first&.facts

      def chat_provider(chat)
        llm_chat = chat.respond_to?(:to_llm) ? chat.to_llm : chat
        llm_chat.instance_variable_get(:@provider)
      end

      def request_output_limit(chat, model_reference)
        params = chat.params if chat.respond_to?(:params)
        Providers::OutputLimit.current(model_reference.provider, params.is_a?(Hash) ? params : {}, model_reference)
      end
    end
  end
end
