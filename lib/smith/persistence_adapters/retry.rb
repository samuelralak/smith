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
        attempts = policy.fetch(:attempts, 3)
        base = policy.fetch(:base_delay, 0.1)
        max_delay = policy.fetch(:max_delay, 1.0)
        last_error = nil

        attempts.times do |i|
          return yield
        rescue *transient => e
          last_error = e
          break if i == attempts - 1

          delay = [base * (2**i), max_delay].min
          logger&.warn(
            "Smith::PersistenceAdapters::Retry #{operation} attempt #{i + 1}/#{attempts} failed: " \
            "#{e.class}: #{e.message}; sleeping #{delay}s"
          )
          sleep(delay)
        end

        raise Smith::PersistenceIOError.new(operation: operation, cause: last_error)
      end
    end
  end
end
