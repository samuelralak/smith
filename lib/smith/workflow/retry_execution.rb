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
      # replayed requests as before.
      def run_with_retry_policy(transition)
        config = transition.retry_config
        @step_attempt = 1
        return run_guarded_step(transition) unless config

        schedule = retry_schedule(config)
        attempt = 0
        key_generation = 0
        begin
          attempt += 1
          @step_attempt = attempt
          run_attempt_under_keys(transition, key_generation)
        rescue StandardError => e
          raise unless retry_transition_error?(config, e, attempt)

          key_generation += 1 if new_idempotency_key_after?(config, e)
          sleep_for_retry(schedule, attempt)
          retry
        end
      end

      def run_attempt_under_keys(transition, key_generation)
        return run_guarded_step(transition) if key_generation.zero?

        IdempotencyKey.within(:key_generation, key_generation) { run_guarded_step(transition) }
      end

      def new_idempotency_key_after?(config, error)
        return true if error.is_a?(DeterministicStepFailure) && error.new_idempotency_key

        config.fetch(:new_idempotency_key_on, EMPTY_ERROR_CLASSES).any? { |error_class| error.is_a?(error_class) }
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

      def sleep_for_retry(schedule, failed_attempt)
        delay = retry_delay(schedule, failed_attempt)
        sleep(delay) if delay.positive?
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
