# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # The waits of durable retries. An attempt that fails in a way a
    # `retry_on ..., durable: true` policy retries does not sleep: the run
    # enters a wait of kind `retry`, due when the backoff ends, and records
    # its pending retry (the transition, the next attempt, and the key
    # generation). `expire_wait!` past the deadline ends the wait without a
    # step and leaves the transition as the run's next; the host continues
    # the run as after any wait, and the step makes the recorded attempt
    # under the recorded keys. The pending retry persists until the step
    # completes or fails, so a crash before then makes the same attempt
    # again.
    module RetryWait
      PENDING_RETRY_FIELDS = %w[attempt key_generation transition].freeze
      private_constant :PENDING_RETRY_FIELDS

      private

      # Enters the wait, due after the backoff, under a token of the attempt
      # it waits to make. Like any wait it is not a step.
      def wait_to_retry(transition, seconds, attempt, key_generation)
        check_wait_ttl!(seconds)
        @awaiting = WaitRecord.build_retry(transition, wait_token_for(transition, ["retry", attempt]), seconds,
                                           Time.now.utc)
        @pending_retry = { "transition" => transition.name.to_s, "attempt" => attempt,
                           "key_generation" => key_generation }.freeze
        record_wait_trace(transition, :retrying)
        WAIT_PENDING
      end

      # [attempts already made, key generation] where the step starts: the
      # pending retry's for its transition, else [0, 0].
      def pending_retry_position(transition)
        pending = @pending_retry
        return [0, 0] unless pending && pending["transition"] == transition.name.to_s

        [pending["attempt"] - 1, pending["key_generation"]]
      end

      # The backoff is over: the wait ends, nothing counts, and the
      # transition is the run's next step. Returns :expired.
      def end_retry_wait(transition)
        @awaiting = nil
        @next_transition_name = transition.name
        @updated_at = Time.now.utc.iso8601(6)
        record_wait_trace(transition, :retry_due)
        :expired
      ensure
        @wait_claimed = false
      end

      # A persisted pending retry names the transition a stored retry wait
      # holds, or else the run's next one, which must declare a durable
      # retry; its attempt is one the policy makes after a failure, and its
      # key generation one an earlier attempt could have reached. A stored
      # retry wait needs one.
      def restore_pending_retry(value)
        return if value.nil? && !retry_waiting?

        record = value.is_a?(Hash) ? value.to_h { |key, field| [key.to_s, field] } : {}
        return record.transform_values(&:freeze).freeze if pending_retry_valid?(record)

        raise Smith::SerializationError, "persisted workflow pending_retry is invalid"
      end

      def retry_waiting? = @awaiting&.fetch("kind") == "retry"

      def pending_retry_valid?(record)
        transition = pending_retry_transition(record)
        record.keys.sort == PENDING_RETRY_FIELDS && transition&.durable_retry? == true &&
          pending_retry_counts?(record, transition.retry_config.fetch(:attempts))
      end

      # The transition the record names, when it is the stored retry wait's,
      # or the run's next while the run does not wait.
      def pending_retry_transition(record)
        return if @awaiting && !retry_waiting?

        name = @awaiting ? @awaiting["transition"] : @next_transition_name&.to_s
        self.class.transition_named(name) if name && record["transition"] == name
      end

      def pending_retry_counts?(record, attempts)
        attempt, generation = record.values_at("attempt", "key_generation")
        attempt.is_a?(Integer) && attempt.between?(2, attempts) && generation.is_a?(Integer) &&
          generation.between?(0, attempt - 1)
      end
    end
  end
end
