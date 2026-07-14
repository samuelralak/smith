# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    module RedisClientAccess
      private

      def client
        return @client if instance_variable_defined?(:@client)

        @client_resolution_mutex.synchronize do
          return @client if instance_variable_defined?(:@client)

          resolved = redis_client?(@redis_source) ? @redis_source : resolve_redis_source
          raise ArgumentError, "Redis client is required" unless resolved

          @client = resolved
        end
      end

      def resolve_redis_source
        @redis_source.respond_to?(:call) ? @redis_source.call : @redis_source
      end

      def redis_client?(candidate)
        candidate.respond_to?(:get) && candidate.respond_to?(:set) && candidate.respond_to?(:del)
      end

      def without_reconnection
        redis = client
        return redis.without_reconnect { yield redis } if redis.respond_to?(:without_reconnect)
        return redis.disable_reconnection { yield redis } if redis.respond_to?(:disable_reconnection)

        raise ArgumentError, "Redis client must expose without_reconnect or disable_reconnection for CAS writes"
      end
    end
  end
end
