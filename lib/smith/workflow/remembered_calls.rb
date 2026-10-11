# frozen_string_literal: true

module Smith
  class Workflow
    # A step's provider calls through a host's response memo
    # (Smith::ResponseMemo): each call takes its kept messages, if any, and
    # sends nothing when they end it (a streamed step's sink gets their text
    # at once), else goes on from them and is recorded as it goes.
    module RememberedCalls
      CALLS_LOCK = Mutex.new
      private_constant :CALLS_LOCK

      private

      def remembered_completion(chat, model_reference, facts, &)
        memo = Smith.config.response_memo
        key = memo && memo_key(facts)
        return yield unless key

        start = chat.messages.length
        kept = ResponseMemo.fetch(memo, key)
        kept&.fetch(:messages)&.each { chat.add_message(_1) }
        return replayed_completion(chat, model_reference) if kept&.fetch(:complete)

        recorded_completion(chat, memo, key, start, &)
      end

      def memo_key(facts) = ResponseMemo.key(@step_attempt.to_i, facts[:attempt_index], next_memo_call)

      def recorded_completion(chat, memo, key, start, &)
        result = ResponseMemo.recording(chat_provider(chat), memo, key, start, &)
        ResponseMemo.store(memo, key, chat.messages.drop(start), complete: true)
        result
      end

      def replayed_completion(chat, model_reference)
        response = chat.messages.last
        if (stream = @step_stream)
          stream.start(attempt: @step_attempt, model: model_reference.model_id,
                       provider: model_reference.provider&.to_s)
          stream.delta(response.content.to_s)
        end
        [response, nil, nil, { memo: true }]
      end

      # The call's place among its attempt's calls at its position (a
      # fan-out's branches count their own).
      def next_memo_call
        slot = [IdempotencyKey.__send__(:current_scope)&.key, @step_attempt]
        memo_calls_lock.synchronize do
          @memo_calls ||= {}
          @memo_calls[slot] = @memo_calls.fetch(slot, 0) + 1
        end
      end

      def memo_calls_lock = @memo_calls_lock || CALLS_LOCK.synchronize { @memo_calls_lock ||= Mutex.new }

      def start_memo_calls = memo_calls_lock.synchronize { @memo_calls = {} }
    end
  end
end
