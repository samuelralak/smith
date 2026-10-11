# frozen_string_literal: true

module Smith
  class Agent
    # The provider calls of a streamed step (Smith::Streaming): before a
    # call that replaces an earlier one, the earlier call's text is
    # withdrawn; each call is announced and its text chunks sent. The stop
    # reason is read from the stream (Providers::StreamFacts), as a
    # streamed reply keeps no raw body.
    module ProviderStreaming
      # Room for what a pause adds besides its messages (its retry, the
      # attempt's usage).
      PAUSE_MARGIN = 4096

      private

      # Withdraws the text a streamed step sent, for `reason`, when a call
      # is about to replace it.
      def withdraw_streamed(reason) = @step_stream&.withdraw(reason)

      # The chat's reply and, for a streamed step, what Completion needs to
      # read its facts. The stream's collection goes into `collected` too,
      # for the facts of a call that fails part way. Requests over the wire
      # are held on the step's budget ledger, if it has one, keyed by the
      # attempt's `attempt_id` (`facts`).
      def complete_chat(chat, model_reference, collected, facts = {})
        return capture_batch_call(chat, model_reference) if @batch_capturing

        entry = take_batch_result
        delivered = deliver_batch_result(chat, entry) if entry
        return delivered if delivered

        remembered_completion(chat, model_reference, facts) do |resumed|
          live_completion(chat, model_reference, collected, facts, resumed)
        end
      end

      # The call over the wire; `resumed` (RememberedCalls) says where a
      # call a response memo kept part of goes on from.
      def live_completion(chat, model_reference, collected, facts, resumed)
        ledger = run_budget_ledger
        return wire_completion(chat, model_reference, collected) unless ledger

        start = resumed ? resumed.start : chat_message_count(chat)
        holding = { pausable: budget_pausable?, rounds: resumed&.rounds || 0 }
        Providers::RequestHolds.within(chat_provider(chat), ledger, facts[:attempt_id], **holding) do |holder|
          held_completion(holder, chat, start) { wire_completion(chat, model_reference, collected) }
        end
      end

      # A refusal of a tool loop's later round pauses the loop (its step
      # retries for budget, BudgetPause): the error carries the messages to
      # continue from (from `start`, a memo's kept rounds included). A loop
      # whose messages cannot be kept goes on, unheld, from its tools'
      # results (the chat keeps them), as when its step cannot pause.
      def held_completion(holder, chat, start)
        yield
      rescue BudgetUnavailable => e
        raise unless holder.pausable && holder.rounds > 1 && e.continuation.nil?

        paused = paused_loop(e, chat, start)
        raise paused if paused

        holder.pausable = false
        retry
      end

      def paused_loop(error, chat, start)
        continuation = Budget::Continuation.dump(@budget_continuation, chat.messages.drop(start || 0))
        BudgetUnavailable.new(error.message, continuation:) if continuation && storable_pause?(continuation)
      end

      # Whether the run's state, with the paused loop kept, stays within
      # persistence_max_bytes: a pause it could not store would lose the
      # loop's paid rounds, so the loop goes on instead.
      def storable_pause?(continuation)
        limit = Smith.config.persistence_max_bytes
        return true unless limit

        JSON.generate(to_state).bytesize + JSON.generate(continuation).bytesize + PAUSE_MARGIN <= limit
      rescue StandardError
        false
      end

      def wire_completion(chat, model_reference, collected)
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

      # The batch result as the chat's reply, and whether the request the
      # call rendered is other than the one sent (a fact of its attempt). A
      # result its call will not use (`on_request_change` :resend or :fail)
      # is set aside, to be charged; :resend returns nil, and the call goes
      # over the wire.
      def deliver_batch_result(chat, entry)
        delivery = @batch_delivery
        response, changed = Providers::BatchExchange.deliver(chat_provider(chat), entry.result, entry.digest,
                                                             on_change: delivery.on_change) { chat.complete }
        [response, nil, :batch, { request_changed: changed || nil }]
      rescue BatchRequestChanged
        delivery.set_aside(Attribution.current&.branch_key, entry)
        raise unless delivery.on_change == :resend
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

        @batch_capture = Providers::BatchExchange::Exchange.new(provider:, holding: !run_budget_ledger.nil?)
        Providers::BatchExchange.within(@batch_capture) { chat.complete }
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
