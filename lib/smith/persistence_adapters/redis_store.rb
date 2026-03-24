# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    class RedisStore
      def initialize(redis:, namespace: "smith")
        @redis_source = redis
        @namespace = namespace
      end

      def store(key, payload)
        client.set(namespaced(key), payload)
      end

      def fetch(key)
        client.get(namespaced(key))
      end

      def delete(key)
        client.del(namespaced(key))
      end

      private

      def client
        @client ||= begin
          resolved = @redis_source.respond_to?(:call) ? @redis_source.call : @redis_source
          raise ArgumentError, "Redis client is required" unless resolved

          resolved
        end
      end

      def namespaced(key)
        [@namespace, key].compact.join(":")
      end
    end
  end
end
