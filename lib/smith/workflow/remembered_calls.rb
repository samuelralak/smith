# frozen_string_literal: true

module Smith
  class Workflow
    # A step's provider calls through a host's response memo
    # (Smith::ResponseMemo): each call takes its kept messages, if any, and
    # sends nothing when they end it (a streamed step's sink gets the reply's
    # text at once), else goes on from them, and is recorded as it goes.
    # Kept tool results count as tools the step ran, charged to its
    # tool-call allowances as they were before the cut; a kept reply whose
    # tools had not run is the answer to the live part's first request, and
    # its tools run. The live part goes on from the kept rounds (Resumed):
    # its first request is a later round, a pause for budget keeps the kept
    # rounds too, and a streamed one's facts pair with its live replies.
    module RememberedCalls
      CALLS_LOCK = Mutex.new
      private_constant :CALLS_LOCK

      # Where a call's live part starts: the call's first message, the
      # rounds its kept messages made, and its kept reply whose tools had
      # not run (one of those rounds).
      Resumed = Data.define(:start, :rounds, :pending)

      private

      def remembered_completion(chat, model_reference, facts, &)
        memo = Smith.config.response_memo
        key = memo && memo_key(chat, facts)
        return yield(nil) unless key

        start = chat.messages.length
        kept = ResponseMemo.fetch(memo, key)
        keep_messages(chat, kept) if kept
        return replayed_completion(chat, model_reference) if kept&.fetch(:complete)

        recorded_completion(chat, memo, key, resumed(start, kept), &)
      end

      def resumed(start, kept)
        return Resumed.new(start:, rounds: 0, pending: nil) unless kept

        pending = kept.fetch(:pending)
        Resumed.new(start:, rounds: kept.fetch(:messages).count { _1.role == :assistant } + (pending ? 1 : 0), pending:)
      end

      def memo_key(chat, facts)
        ResponseMemo.key([*@memo_attempts, @step_attempt.to_i], facts[:attempt_index], next_memo_call, chat)
      end

      # The kept messages, after the call's own; their tool results are
      # tools the step ran, each charged as it was.
      def keep_messages(chat, kept)
        messages = kept.fetch(:messages)
        messages.each { chat.add_message(_1) }
        ran = messages.filter_map { _1.tool_call_id if _1.role == :tool }
        Tool.current_tool_execution_tracker&.mark_started! if ran.any?
        charge_kept_calls(ran_calls(messages, ran))
      end

      def ran_calls(messages, ran) = messages.flat_map { _1.tool_calls&.values.to_a }.select { ran.include?(_1.id) }

      # Each kept call against the agent's tool-call allowance and the
      # workflow's `tool_calls` budget, as a call that runs is, so a replay
      # runs no more tools than the step may. A call past them (a budget
      # lowered since, or a call rejected for budget) charges nothing more.
      def charge_kept_calls(calls)
        allowance = Tool.current_tool_call_allowance
        ledger = Tool.current_ledger
        commit = -> { ledger.reconcile!(ledger.reserve!(:tool_calls, 1), 1) if ledger&.limits&.key?(:tool_calls) }
        calls.each { allowance.is_a?(Tool::CallAllowance) ? allowance.charge!(_1.name, &commit) : commit.call }
      rescue BudgetExceeded
        nil
      end

      # A call a tool halted ends in that tool's result, not a reply: it
      # keeps its progress, which a replay can go on from.
      def recorded_completion(chat, memo, key, resumed)
        result = ResponseMemo.recording(chat_provider(chat), memo, key, resumed.start, resumed.pending) do
          yield(resumed)
        end
        messages = chat.messages.drop(resumed.start)
        if ResponseMemo.answer?(messages.last)
          ResponseMemo.store(memo, key, messages, complete: true, facts: streamed_facts(messages, result))
        end
        result
      end

      # A streamed call's replies' facts, read from its stream (its kept
      # replies, which no round of it answered, keep their own).
      def streamed_facts(messages, result)
        stream = result[1]
        return {} unless stream.is_a?(Hash) && stream[:rounds]

        replies = messages.select { _1.role == :assistant }
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
