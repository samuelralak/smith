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
    Wait = Data.define(:kind, :event, :token, :transition, :into, :entered_at, :deadline_at, :children)

    # Entering, resuming and expiring `await` and `delay` steps. Entering a
    # wait is not a step: `step_count` stays, so the step's position and its
    # token (a key under a position reserved for the wait) are the same when
    # the wait is entered, when its block runs again after a crash, and when
    # it completes. The completion (`resume!`, or `expire_wait!` past the
    # deadline) is the step. One completion at a time claims the wait, so a
    # delivery and an expiry racing on one instance cannot both win.
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
      # the step's `into:` key and completes the step. A delivery can arrive
      # before the wait is stored (the block's request answered at once);
      # when the run stands at that await and the token is the one it will
      # use, the step completes at once, without running the block.
      # Returns `:resumed`, `:failed` when the completion took the failure
      # path, or `:stale` (changing nothing) for any other event or token.
      def resume!(event:, token:, payload:)
        transition = claim_wait { resumable_transition(event.to_s, token.to_s) }
        return :stale unless transition

        value = claimed_payload(transition, payload)
        complete_claimed_wait(transition, :resumed) do
          transition.child_runs? ? deliver_child_results(transition, value) : write_wait_payload(transition, value)
          StepCompletion.instance_method(:complete_step).bind_call(self, transition, nil)
        end
      end

      # Ends a wait whose deadline has passed at `now` (a Time, or an
      # ISO 8601 String): a `delay` continues to its `to:`, an `await` takes
      # `on_timeout`, or else its `on_failure` with Smith::WaitTimedOut.
      # Returns `:expired`, `:not_due`, or `:stale` unless the run waits
      # under this token.
      def expire_wait!(token:, now: Time.now.utc)
        now = wait_time(now)
        record = @awaiting
        not_due = false
        transition = claim_wait do
          next if record.nil? || !record.equal?(@awaiting) || record["token"] != token.to_s

          not_due = now < wait_deadline(record)
          awaited_transition(record) unless not_due
        end
        return not_due ? :not_due : :stale unless transition

        complete_claimed_wait(transition, :expired) { expire_step(transition, record) }
      end

      private

      # Runs the step's block, if any, then either finishes inline (the
      # block called `resolve!`) or records the wait and returns
      # WAIT_PENDING, which tells `advance!` the step has not completed. The
      # payload key and the store's TTL are checked before the block sends
      # anything.
      def execute_await_step(transition)
        check_deadline!
        seconds = WaitRecord.seconds(transition.await_config.fetch(:timeout), snapshot_value(@context))
        check_wait_admissible!(transition, seconds)
        token = await_token_for(transition)
        settled = settle_on_entry(transition, token)
        return settled unless wait_pending?(settled)

        enter_wait(transition, token, seconds)
        WAIT_PENDING
      end

      # Runs the step's entry: an await's block, or a map's or call's
      # launch. The step settles at once when the block resolves the wait or
      # the launcher ran the children itself; otherwise WAIT_PENDING.
      def settle_on_entry(transition, token)
        if transition.child_runs?
          results = launch_child_runs(transition, token)
          return WAIT_PENDING unless results

          payload = child_results_payload(collectable_results(transition.children_config, results))
          return deliver_child_results(transition, payload, @launched_children)
        end

        step = run_await_block(transition, token) if transition.await_config[:block]
        step&.resolved? ? write_wait_payload(transition, wait_payload(step.payload)) : WAIT_PENDING
      end

      def wait_pending?(value) = value.equal?(WAIT_PENDING)

      # The delivered payload, normalized for the claimed step: a map's
      # results checked against its children, anything else bounded like a
      # session message. A payload that does not fit raises to the host and
      # frees the wait.
      def claimed_payload(transition, payload)
        return wait_payload(payload) unless transition.child_runs?

        entries = child_results_payload(collectable_results(transition.children_config, payload))
        checked_child_results(entries, expected_children(transition), transition.children_config[:kind])
      rescue StandardError
        @wait_claimed = false
        raise
      end

      # The wait's token: a key of the step's position under a segment only
      # waits use, so no `idempotency_key` scope can produce it, and
      # computable before the wait is stored. A wait is never nested (an
      # in-process child cannot wait), so the position is the run's own.
      def await_token_for(transition)
        config = transition.await_config
        IdempotencyKey.__send__(:root_scope, ArtifactIntegration.instance_method(:execution_namespace).bind_call(self))
                      .within(:step, @step_count + 1, transition.name.to_s).within(:wait)
                      .key([config.fetch(:kind), config[:event]].compact)
      end

      def check_wait_admissible!(transition, seconds)
        writable_wait_key!(transition) if transition.await_config[:into]
        ttl = self.class.persistence_ttl || Smith.config.persistence_ttl
        return unless @persistence_key && ttl && seconds > ttl

        raise WorkflowError, "a wait of #{seconds} seconds outlasts the persistence TTL of #{ttl} seconds; " \
                             "the stored run would expire before the wait ends"
      end

      def run_await_block(transition, token)
        step = AwaitStep.new(context: snapshot_value(@context), await_token: token,
                             idempotency_scope: IdempotencyKey.__send__(:current_scope!),
                             attempt: @step_attempt || 1, transition_name: transition.name)
        transition.await_config.fetch(:block).call(step)
        step
      end

      def enter_wait(transition, token, seconds)
        children = @launched_children if transition.child_runs?
        @awaiting = WaitRecord.build(transition, token, seconds, Time.now.utc, children:)
        record_wait_trace(transition, :waiting)
      end

      def record_wait_trace(transition, outcome)
        Smith::Trace.record(
          type: :transition, data: { transition: transition.name, from: transition.from, to: transition.to, outcome: }
        )
      end
    end
  end
end
