# frozen_string_literal: true

module Smith
  class Workflow
    module RetryExecution
      private

      def run_with_retry_policy(transition)
        config = transition.retry_config
        return run_guarded_step(transition) unless config

        schedule = retry_schedule(config)
        attempt = 0
        begin
          attempt += 1
          run_guarded_step(transition)
        rescue StandardError => e
          raise unless retry_transition_error?(config, e, attempt)

          sleep_for_retry(schedule, attempt)
          retry
        end
      end

      def retry_transition_error?(config, error, attempt)
        return false if attempt >= config.fetch(:attempts)

        classes = config.fetch(:error_classes)
        if classes.any?
          classes.any? { |error_class| error.is_a?(error_class) }
        else
          Smith::Errors.retryable?(error)
        end
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
