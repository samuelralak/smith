# frozen_string_literal: true

require "time"

require_relative "message_value_normalizer"

module Smith
  class Workflow
    # Completing a wait, by delivery or expiry: claiming it so only one
    # completion wins, running the completion as the step, and the timeout
    # route. Part of WaitExecution, split out for size.
    module WaitCompletion
      private

      # The awaited transition when the delivery matches the stored wait, or
      # when no wait is stored yet but the run stands at that await and the
      # token is the one entering it will use.
      def resumable_transition(event, token)
        record = @awaiting
        return (awaited_transition(record) if record["event"] == event && record["token"] == token) if record

        transition = pending_await_transition
        return unless transition && transition.await_config[:event].to_s == event
        return unless await_token_for(transition) == token

        transition
      end

      def pending_await_transition
        transition = self.class.find_transition(@next_transition_name || self.class.first_transition_from(@state)&.name)
        transition if transition&.awaits? && !transition.delay? && [nil, @state].include?(transition.from)
      end

      def claim_wait
        (@wait_mutex ||= Mutex.new).synchronize do
          return nil if @wait_claimed

          claimed = yield
          @wait_claimed = true if claimed
          claimed
        end
      end

      def complete_claimed_wait(transition, done, &)
        step = finish_wait(transition, &)
        step.key?(:error) && done == :resumed ? :failed : done
      ensure
        @wait_claimed = false
      end

      def expire_step(transition, record)
        return StepCompletion.instance_method(:complete_step).bind_call(self, transition, nil) if transition.delay?
        return route_to_timeout!(transition) if transition.timeout_transition

        raise WaitTimedOut.new(transition: transition.name, event: record["event"], deadline_at: record["deadline_at"])
      end

      # The await ends without reaching its `to:`; the run stays in its
      # `from:` state and takes `on_timeout` next. Hosts see a StepCompleted
      # whose `to` is that state.
      def route_to_timeout!(transition)
        name = transition.timeout_transition
        target = self.class.find_transition(name) || raise(UnresolvedTransitionError.new(name, self.class, @state))
        validate_transition_origin!(target)
        @next_transition_name = name
        record_wait_trace(transition, :timed_out)
        emit_step_completed(TimedOutStep.new(transition.name, transition.from, @state), nil)
        { transition: transition.name, from: transition.from, to: @state, timed_out: true }
      end

      TimedOutStep = Struct.new(:name, :from, :to)
      private_constant :TimedOutStep

      # A payload is bounded and JSON-shaped like a session message, and
      # takes the context's key shape. It never enters the session.
      def wait_payload(payload)
        ContextKeys.normalize(MessageValueNormalizer.new(payload, label: "wait payload").call)
      end

      # Returns nil, the inline-resolved step's output.
      def write_wait_payload(transition, value)
        key = writable_wait_key!(transition)
        @context[key] = value
        record_persisted_key!(key)
        nil
      end

      def writable_wait_key!(transition)
        key = transition.await_config.fetch(:into)
        keys = declared_persist_keys
        raise UndeclaredContextKey.new(key:, persisted_keys: keys) if keys && !keys.include?(key)

        key
      end

      def wait_time(now)
        return now.utc if now.is_a?(Time)
        return Time.iso8601(now).utc if now.is_a?(String)
        return now.to_time.utc if now.respond_to?(:to_time)

        raise ArgumentError, "now: must be a Time or an ISO 8601 String"
      end

      def wait_deadline(record) = Time.iso8601(record.fetch("deadline_at"))

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
