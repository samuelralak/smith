# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    class CacheStore
      # Cache backends vary widely; the transient list is intentionally
      # broad. Hosts using a specific backend can subclass and tighten.
      # NOTE: NO store_versioned implementation — cache backends don't
      # have uniform CAS semantics. Workflow#persist! checks via
      # respond_to? and falls back to non-versioned store + warning.
      TRANSIENT_ERRORS = [
        Errno::ECONNREFUSED,
        Errno::ETIMEDOUT,
        Errno::EPIPE,
        IOError
      ].freeze

      def initialize(store:, namespace: "smith")
        @store_source = store
        @namespace = namespace
      end

      def store(key, payload, ttl: Smith.config.persistence_ttl)
        Retry.with_retries(operation: :store, transient: TRANSIENT_ERRORS) do
          if ttl
            backend.write(namespaced(key), payload, expires_in: ttl)
          else
            backend.write(namespaced(key), payload)
          end
        end
      end

      def fetch(key)
        Retry.with_retries(operation: :fetch, transient: TRANSIENT_ERRORS) do
          backend.read(namespaced(key))
        end
      end

      def delete(key)
        Retry.with_retries(operation: :delete, transient: TRANSIENT_ERRORS) do
          backend.delete(namespaced(key))
        end
      end

      def backend_name
        backend.class.name || backend.class.to_s
      end

      def durability_warning
        process_local_backend_warning
      end

      private

      def backend
        @backend ||= begin
          store = @store_source.respond_to?(:call) ? @store_source.call : @store_source
          raise ArgumentError, "cache store is required" unless store

          store
        end
      end

      def namespaced(key)
        [@namespace, key].compact.join(":")
      end

      def process_local_backend_warning
        return nil unless process_local_memory_backend?

        "#{backend_name} is process-local memory and will not survive restarts"
      end

      def process_local_memory_backend?
        backend_name.end_with?("MemoryStore")
      end
    end
  end
end
