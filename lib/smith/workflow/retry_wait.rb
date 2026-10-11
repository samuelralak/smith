# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # The waits of durable retries. An attempt that fails in a way a
    # `retry_on ..., durable: true` policy retries does not sleep: the run
    # enters a wait of kind `retry`, due when the backoff ends, and records
    # its pending retry (the transition, the next attempt, its key
    # generation, and the class of the error that failed the last attempt).
    # `expire_wait!` past the deadline ends the wait without a step and
    # leaves the transition as the run's next; the host continues the run as
    # after any wait, and the step makes the recorded attempt under the
    # recorded keys. A step that ends without entering a wait clears the
    # pending retry (Workflow#advance!).
    module RetryWait
      PENDING_RETRY_FIELDS = %w[attempt error key_generation transition].freeze
      private_constant :PENDING_RETRY_FIELDS

      private

      # Enters the wait, due after the backoff, under a token of the attempt
      # it waits to make. Like any wait it is not a step. The pending retry
      # is recorded before the wait, so an interrupt between the two leaves
      # a step that ended without a wait, whose pending retry is cleared.
      def wait_to_retry(transition, seconds, attempt, key_generation, error)
        if @split_step_phase == :executing
          raise WorkflowError, "a durable retry cannot wait inside split-step execution"
        end

        check_wait_ttl!(seconds)
        error_name = DiagnosticText.error_class_name(error)
        @pending_retry = { "transition" => transition.name.to_s, "attempt" => attempt,
                           "key_generation" => key_generation, "error" => error_name }.freeze
        @retry_wait_error = error
        @awaiting = WaitRecord.build_retry(transition, wait_token_for(transition, ["retry", attempt]), seconds,
                                           Time.now.utc)
        record_retry_trace(transition, :retrying, attempt:, error: error_name, deadline_at: @awaiting["deadline_at"])
        WAIT_PENDING
      end

      # A step that ran and did not enter a wait has made its pending retry,
      # whether it completed, failed or raised.
      def clear_settled_pending_retry
        @pending_retry = nil if step_work_started? && !waiting?
      end

      # [attempts already made, key generation] where the step starts: the
      # pending retry's for its transition, else [0, 0].
      def pending_retry_position(transition)
        pending = @pending_retry
        return [0, 0] unless pending && pending["transition"] == transition.name.to_s

        [pending["attempt"] - 1, pending["key_generation"]]
      end

      # The backoff is over: the transition becomes the run's next step, then
      # the wait ends; nothing counts. Returns :expired.
      def end_retry_wait(transition)
        @next_transition_name = transition.name
        @updated_at = Time.now.utc.iso8601(6)
        @awaiting = nil
        Attribution.with(execution_key: @persistence_key, workflow: self.class.name || "anonymous") do
          record_retry_trace(transition, :retry_due, attempt: @pending_retry&.fetch("attempt"))
        end
        :expired
      ensure
        @wait_claimed = false
      end

      def record_retry_trace(transition, outcome, **details)
        Smith::Trace.record(
          type: :transition,
          data: { transition: transition.name, from: transition.from, to: transition.to, outcome:, **details }
        )
      end

      # The error that failed the attempt a retry wait follows, while this
      # instance holds it (for a nested child's parent).
      def retry_wait_error = (@retry_wait_error if retry_waiting?)

      # A persisted pending retry names the transition of the stored retry
      # wait, or else the run's next one, with an attempt after the first, a
      # key generation an earlier attempt could reach, and an error class
      # name; a stored retry wait needs one. A malformed one raises
      # SerializationError; one the class no longer allows (the transition
      # declares no durable retry, or fewer attempts) is refused like an
      # unknown position.
      def restore_pending_retry(value, persistence_key)
        return if value.nil? && !retry_waiting?

        record = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
        transition = pending_retry_transition(record)
        raise Smith::SerializationError, "persisted workflow pending_retry is invalid" unless
          well_formed_pending_retry?(transition, record)

        refuse_disallowed_pending_retry!(transition, record, persistence_key)
        record.transform_values(&:freeze).freeze
      end

      def retry_waiting? = @awaiting&.fetch("kind") == "retry"

      # The transition the record names, when it is the stored retry wait's,
      # or the run's next while the run does not wait.
      def pending_retry_transition(record)
        return if @awaiting && !retry_waiting?

        name = @awaiting ? @awaiting["transition"] : @next_transition_name&.to_s
        self.class.transition_named(name) if name && record["transition"] == name
      end

      def well_formed_pending_retry?(transition, record)
        !transition.nil? && record.keys.sort == PENDING_RETRY_FIELDS && pending_retry_fields?(record)
      end

      def pending_retry_fields?(record)
        attempt, generation, error = record.values_at("attempt", "key_generation", "error")
        attempt.is_a?(Integer) && attempt >= 2 && generation.is_a?(Integer) && generation.between?(0, attempt - 1) &&
          error.is_a?(String) && error.bytesize.between?(1, 256)
      end

      def refuse_disallowed_pending_retry!(transition, record, persistence_key)
        return if transition.durable_retry? && record["attempt"] <= transition.retry_config.fetch(:attempts)

        raise Smith::UnknownTransitionOnRestore.new(workflow: self.class.name, persistence_key:,
                                                    transition: transition.name)
      end
    end
  end
end
