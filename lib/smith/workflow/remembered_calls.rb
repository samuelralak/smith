# frozen_string_literal: true

module Smith
  class Workflow
    # A step's provider calls through a host's response memo
    # (Smith::ResponseMemo): each call takes its kept messages, if any, and
    # sends nothing when they end it (a streamed step's sink gets the reply's
    # text at once), else goes on from them, and is recorded as it goes.
    # Kept tool results count as tools the step ran, and the live part goes
    # on from the kept rounds (Resumed): its first request is a later round,
    # and a pause for budget keeps the kept rounds too.
    module RememberedCalls
      CALLS_LOCK = Mutex.new
      private_constant :CALLS_LOCK

      # Where a call's live part starts: the call's first message, and the
      # rounds its kept messages made.
      Resumed = Data.define(:start, :rounds)

      private

      def remembered_completion(chat, model_reference, facts, &)
        memo = Smith.config.response_memo
        key = memo && memo_key(chat, facts)
        return yield(nil) unless key

        start = chat.messages.length
        kept = ResponseMemo.fetch(memo, key)
        keep_messages(chat, kept.fetch(:messages)) if kept
        return replayed_completion(chat, model_reference) if kept&.fetch(:complete)

        recorded_completion(chat, memo, key, Resumed.new(start:, rounds: kept_rounds(kept)), &)
      end

      def kept_rounds(kept) = kept ? kept.fetch(:messages).count { _1.role == :assistant } : 0

      def memo_key(chat, facts)
        ResponseMemo.key([*@memo_attempts, @step_attempt.to_i], facts[:attempt_index], next_memo_call, chat)
      end

      # The kept messages, after the call's own; their tool results are
      # tools the step ran.
      def keep_messages(chat, messages)
        messages.each { chat.add_message(_1) }
        Tool.current_tool_execution_tracker&.mark_started! if messages.any? { _1.role == :tool }
      end

      def recorded_completion(chat, memo, key, resumed)
        live = chat.messages.length
        result = ResponseMemo.recording(chat_provider(chat), memo, key, resumed.start) { yield(resumed) }
        ResponseMemo.store(memo, key, chat.messages.drop(resumed.start), complete: true,
                                                                         facts: streamed_facts(chat, live, result))
        result
      end

      # A streamed call's replies' facts, read from its stream.
      def streamed_facts(chat, live, result)
        stream = result[1]
        return {} unless stream.is_a?(Hash) && stream[:rounds]

        replies = chat.messages.drop(live).select { _1.role == :assistant }
        replies.zip(Providers::StreamFacts.per_message(replies, stream[:rounds], stream[:output_limit]))
               .to_h.compare_by_identity
      end

      def replayed_completion(chat, model_reference)
        response = chat.messages.last
        if (stream = @step_stream)
          stream.start(attempt: @step_attempt, model: model_reference.model_id,
                       provider: model_reference.provider&.to_s)
          content = response.content
          stream.delta(content.is_a?(String) ? content : JSON.generate(content))
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
