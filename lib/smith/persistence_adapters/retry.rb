# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    # Generic retry-with-exponential-backoff wrapper used by adapter
    # store/fetch/delete/store_versioned operations to survive transient
    # I/O errors. After attempts exhausted, raises Smith::PersistenceIOError
    # wrapping the underlying cause.
    #
    # Adapter-agnostic: each adapter passes its own `transient:` error
    # class list because Redis transient errors differ from AR transient
    # errors differ from cache-backend transient errors. The Memory
    # adapter passes an empty list (it never raises transient errors).
    module Retry
      module_function

      def with_retries(operation:, transient:, policy: Smith.config.persistence_retry_policy,
                       logger: Smith.config.logger)
        schedule = schedule_for(policy)
        last_error = nil

        schedule.attempts.times do |i|
          return yield
        rescue *transient => e
          last_error = e
          break if i == schedule.attempts - 1

          delay = schedule.delay(i + 1)
          log_retry(logger, operation, e, { attempt: i + 1, attempts: schedule.attempts, delay: })
          sleep(delay)
        end

        raise Smith::PersistenceIOError.new(operation: operation, cause: last_error)
      end

      def schedule_for(policy)
        ExponentialBackoff.new(
          attempts: policy.fetch(:attempts, 3),
          base_delay: policy.fetch(:base_delay, 0.1),
          max_delay: policy.fetch(:max_delay, 1.0),
          jitter: 0
        )
      end

      def log_retry(logger, operation, error, retry_context)
        logger&.warn(
          "Smith::PersistenceAdapters::Retry #{operation} " \
          "attempt #{retry_context.fetch(:attempt)}/#{retry_context.fetch(:attempts)} failed: " \
          "#{error.class}: #{error.message}; sleeping #{retry_context.fetch(:delay)}s"
        )
      end
    end
  end
end
