# frozen_string_literal: true

module Smith
  class Workflow
    module RetryExecution
      private

      # `@step_attempt` is the attempt under way, from 1, which the optimizer
      # names its verdicts by; transient, set here before every attempt.
      #
      # Every attempt sends its requests under the step's idempotency keys,
      # so a retry after an uncertain failure (a timeout, a lost connection)
      # cannot repeat a request that took effect. Only an attempt that
      # failed in a way the step declares settled moves later attempts to
      # new keys. Attempts replay in the same order after a restore, so a
      # replay reaches the same keys as long as the receivers answer the
      # replayed requests as before. A durable policy waits out the backoff
      # as a wait of the run (RetryWait) and resumes at the attempt and key
      # generation it recorded.
      def run_with_retry_policy(transition)
        config = transition.retry_config
        position = pending_batch_position
        @step_attempt = position ? position.first + 1 : 1
        @step_key_generation = position ? position.last : 0
        return run_guarded_step(transition) unless config

        run_attempts(transition, config, *(position || pending_retry_position(transition)))
      end

      # Attempts after the `attempt` already made, under `key_generation`.
      def run_attempts(transition, config, attempt, key_generation)
        schedule = retry_schedule(config)
        begin
          attempt += 1
          @step_attempt = attempt
          @step_key_generation = key_generation
          attempt_scope = attempt_idempotency_scope(key_generation)
          run_attempt_under_keys(transition, attempt_scope)
        rescue StandardError => e
          raise unless retry_transition_error?(config, e, attempt)

          key_generation += 1 if new_idempotency_key_after?(config, e, attempt_scope)
          delay = retry_delay(schedule, attempt)
          return wait_to_retry(transition, delay, attempt + 1, key_generation, e) if config[:durable]

          sleep(delay) if delay.positive?
          retry
        end
      end

      def attempt_idempotency_scope(key_generation)
        step_scope = IdempotencyKey.__send__(:current_scope)
        return step_scope if step_scope.nil? || key_generation.zero?

        step_scope.within(:key_generation, key_generation)
      end

      def run_attempt_under_keys(transition, attempt_scope)
        return run_guarded_step(transition) if attempt_scope.equal?(IdempotencyKey.__send__(:current_scope))

        IdempotencyKey.__send__(:swap, attempt_scope) { run_guarded_step(transition) }
      end

      # A `fail!(new_idempotency_key: true)` counts only when this step's own
      # attempt raised it, never a nested workflow's step, whose flag speaks
      # for its own requests and not for the earlier steps of the attempt.
      def new_idempotency_key_after?(config, error, attempt_scope)
        return true if own_settled_failure?(error, attempt_scope)

        config.fetch(:new_idempotency_key_on, EMPTY_ERROR_CLASSES).any? { |error_class| error.is_a?(error_class) }
      end

      def own_settled_failure?(error, attempt_scope)
        error.is_a?(DeterministicStepFailure) && error.new_idempotency_key &&
          !attempt_scope.nil? && error.idempotency_scope == attempt_scope
      end

      EMPTY_ERROR_CLASSES = [].freeze
      private_constant :EMPTY_ERROR_CLASSES

      def retry_transition_error?(config, error, attempt)
        return false if attempt >= config.fetch(:attempts)
        return false if terminal_retry_error?(error)

        return false if retry_deadline_passed?

        classes = config.fetch(:error_classes)
        if classes.any?
          classes.any? { |error_class| error.is_a?(error_class) }
        else
          Smith::Errors.retryable?(error)
        end
      end

      # No attempt starts once the wall-clock deadline has passed: it could
      # only fail again, after sleeping through its backoff.
      def retry_deadline_passed?
        deadline = effective_deadline
        !deadline.nil? && Time.now.utc >= deadline
      end

      def terminal_retry_error?(error)
        Smith::Errors.retry_forbidden?(error)
      end

      def retry_delay(config_or_schedule, failed_attempt)
        schedule = if config_or_schedule.is_a?(ExponentialBackoff)
                     config_or_schedule
                   else
                     retry_schedule(config_or_schedule)
                   end
        schedule.delay(failed_attempt, random: method(:rand))
      end

      def retry_schedule(config)
        ExponentialBackoff.new(
          attempts: config.fetch(:attempts),
          base_delay: config.fetch(:backoff),
          max_delay: config[:max_delay],
          jitter: config.fetch(:jitter),
          delay_label: "backoff"
        )
      end
    end
  end
end
