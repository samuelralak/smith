# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    class CacheStore
      def initialize(store:, namespace: "smith")
        @store_source = store
        @namespace = namespace
      end

      def store(key, payload)
        backend.write(namespaced(key), payload)
      end

      def fetch(key)
        backend.read(namespaced(key))
      end

      def delete(key)
        backend.delete(namespaced(key))
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
