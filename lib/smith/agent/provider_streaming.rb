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
        return capture_batch_call(chat, model_reference) if @batch_capturing

        result = take_batch_result
        return [Providers::BatchExchange.deliver(chat_provider(chat), result) { chat.complete }, nil, :batch] if result

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

      # A batch step's call: the provider must have a batch interface (only
      # Anthropic's, so far) and the agent no tools (a batch request is one
      # turn). The request is thrown out of the call before it is sent.
      def capture_batch_call(chat, model_reference)
        provider = chat_provider(chat)
        unless provider.respond_to?(:slug) && provider.slug.to_s == "anthropic"
          raise BatchModeUnavailable, "#{model_reference.provider || "this provider"} has no batch interface in Smith"
        end
        raise BatchModeUnavailable, "a batch request is one turn: its agent cannot have tools" if chat_tools?(chat)

        Providers::BatchExchange.within(Providers::BatchExchange::Exchange.new(provider, nil)) { chat.complete }
        raise BatchModeUnavailable, "the call did not reach its provider's request"
      end

      def chat_tools?(chat)
        tools = chat.tools if chat.respond_to?(:tools)
        tools.respond_to?(:empty?) && !tools.empty?
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
