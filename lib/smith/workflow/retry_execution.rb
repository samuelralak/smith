# frozen_string_literal: true

module Smith
  class Workflow
    module RetryExecution
      private

      def run_with_retry_policy(transition)
        config = transition.retry_config
        return run_guarded_step(transition) unless config

        attempt = 0
        begin
          attempt += 1
          run_guarded_step(transition)
        rescue StandardError => e
          raise unless retry_transition_error?(config, e, attempt)

          sleep_for_retry(config, attempt)
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

      def sleep_for_retry(config, failed_attempt)
        delay = retry_delay(config, failed_attempt)
        sleep(delay) if delay.positive?
      end

      def retry_delay(config, failed_attempt)
        delay = config.fetch(:backoff) * (2**[failed_attempt - 1, 0].max)
        max_delay = config[:max_delay]
        delay = [delay, max_delay].min if max_delay

        jitter = config.fetch(:jitter)
        delay += rand * jitter if jitter.positive?
        delay = [delay, max_delay].min if max_delay
        delay
      end
    end
  end
end
