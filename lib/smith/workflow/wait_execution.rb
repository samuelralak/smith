# frozen_string_literal: true

require "time"

require_relative "await_step"
require_relative "message_value_normalizer"

module Smith
  class Workflow
    # The wait a run is in: an `await` for `event` (delivered under `token`
    # by `resume!`) or a `delay`, entered at `entered_at` and due to expire at
    # `deadline_at`. Hosts index it to deliver events and to schedule the
    # `expire_wait!` call; Smith never sleeps, polls or wakes a run itself.
    Wait = Data.define(:kind, :event, :token, :transition, :into, :entered_at, :deadline_at)

    # Entering, resuming and expiring `await` and `delay` steps. Entering a
    # wait is not a step: `step_count` stays, so the step's position, its
    # idempotency keys and its token are the same when the wait is entered,
    # when its block runs again after a crash, and when it completes. The
    # completion (`resume!`, or `expire_wait!` past the deadline) is the step.
    module WaitExecution
      WAIT_PENDING = Object.new.freeze
      private_constant :WAIT_PENDING

      def waiting? = !@awaiting.nil?

      # The run's wait, or nil.
      def awaiting
        record = @awaiting
        WaitRecord.to_wait(record, awaited_transition(record)) if record
      end

      # Delivers the event this run awaits: writes the normalized payload to
      # the step's `into:` key and completes the step. Returns `:resumed`, or
      # `:stale` (and changes nothing) unless the run awaits this event under
      # this token.
      def resume!(event:, token:, payload:)
        record = @awaiting
        # A delay has no event, so no delivery ever matches one.
        return :stale unless record && record["event"] == event.to_s && record["token"] == token.to_s

        transition = awaited_transition(record)
        value = wait_payload(payload)
        finish_wait(transition) do
          write_wait_payload(transition, value)
          StepCompletion.instance_method(:complete_step).bind_call(self, transition, nil)
        end
        :resumed
      end

      # Ends a wait whose deadline has passed at `now`: a `delay` continues to
      # its `to:`, an `await` takes `on_timeout`, or else the failure path
      # with Smith::WaitTimedOut. Returns `:expired`, `:not_due`, or `:stale`
      # unless the run waits under this token.
      def expire_wait!(token:, now: Time.now.utc)
        record = @awaiting
        return :stale unless record && record["token"] == token.to_s
        return :not_due if now < Time.iso8601(record.fetch("deadline_at"))

        transition = awaited_transition(record)
        finish_wait(transition) do
          next StepCompletion.instance_method(:complete_step).bind_call(self, transition, nil) if transition.delay?

          time_out!(transition, record)
        end
        :expired
      end

      private

      # Runs the step's block, if any, then either finishes inline (the
      # block called `resolve!`) or records the wait and returns
      # WAIT_PENDING, which tells `advance!` the step has not completed.
      def execute_await_step(transition)
        check_deadline!
        config = transition.await_config
        scope = IdempotencyKey.__send__(:current_scope!)
        token = await_token(scope, config)
        seconds = WaitRecord.seconds(config.fetch(:timeout), snapshot_value(@context))
        step = run_await_block(transition, scope, token) if config[:block]
        return write_wait_payload(transition, wait_payload(step.payload)) if step&.resolved?

        enter_wait(transition, token, seconds)
        WAIT_PENDING
      end

      def wait_pending?(value) = value.equal?(WAIT_PENDING)

      # The step's key for its wait: the same each time the step is entered.
      def await_token(scope, config) = scope.key([config.fetch(:kind), config[:event]].compact)

      def run_await_block(transition, scope, token)
        step = AwaitStep.new(context: snapshot_value(@context), await_token: token, idempotency_scope: scope,
                             attempt: @step_attempt || 1, transition_name: transition.name)
        transition.await_config.fetch(:block).call(step)
        step
      end

      def enter_wait(transition, token, seconds)
        @awaiting = WaitRecord.build(transition, token, seconds, Time.now.utc)
        Smith::Trace.record(
          type: :transition,
          data: { transition: transition.name, from: transition.from, to: transition.to, outcome: :waiting }
        )
      end

      # A payload is bounded and JSON-shaped like a session message, and
      # takes the context's key shape. It never enters the session.
      def wait_payload(payload)
        ContextKeys.normalize(MessageValueNormalizer.new(payload, label: "wait payload").call)
      end

      # Returns nil, the inline-resolved step's output.
      def write_wait_payload(transition, value)
        key = transition.await_config.fetch(:into)
        keys = declared_persist_keys
        raise UndeclaredContextKey.new(key:, persisted_keys: keys) if keys && !keys.include?(key)

        @context[key] = value
        record_persisted_key!(key)
        nil
      end

      def time_out!(transition, record)
        unless transition.timeout_transition
          raise WaitTimedOut.new(transition: transition.name, event: record["event"],
                                 deadline_at: record.fetch("deadline_at"))
        end

        route_to_timeout!(transition)
      end

      def route_to_timeout!(transition)
        name = transition.timeout_transition
        target = self.class.find_transition(name) || raise(UnresolvedTransitionError.new(name, self.class, @state))
        validate_transition_origin!(target)
        @next_transition_name = name
        Smith::Trace.record(
          type: :transition,
          data: { transition: transition.name, from: transition.from, to: transition.to, outcome: :timed_out }
        )
        { transition: transition.name, from: transition.from, to: nil, timed_out: true }
      end

      # The completion of a wait is the step: it runs in the step's context
      # (so its position, attribution and events are the step's), then
      # counts. A completion that raises leaves the run waiting.
      def finish_wait(transition, &)
        step = with_step_context(transition, &)
        @awaiting = nil
        @step_count += 1
        @updated_at = Time.now.utc.iso8601(6)
        record_step_snapshot(step)
        step
      end

      def awaited_transition(record)
        self.class.transition_named(record.fetch("transition")) ||
          raise(WorkflowError, "the awaited transition is not declared")
      end
    end
  end
end
