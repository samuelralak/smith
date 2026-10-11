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
      # read its facts.
      def complete_chat(chat, model_reference)
        stream = @step_stream
        return [chat.complete, nil] unless stream

        stream.start(attempt: @step_attempt, model: model_reference.model_id, provider: model_reference.provider&.to_s)
        response = nil
        facts = Providers::StreamFacts.collect { response = chat.complete { |chunk| stream.delta(chunk.content) } }
        [response, { facts:, output_limit: request_output_limit(chat, model_reference) }]
      end

      def request_output_limit(chat, model_reference)
        params = chat.params if chat.respond_to?(:params)
        Providers::OutputLimit.current(model_reference.provider, params.is_a?(Hash) ? params : {}, model_reference)
      end
    end
  end
end
