# frozen_string_literal: true

require "time"

module Smith
  module PersistenceAdapters
    class RedisStore
      # Redis transient errors — narrow list; non-transient errors
      # (CommandError, etc.) propagate up immediately. Pattern matches
      # Redis::BaseConnectionError if loaded (covers Connection/Timeout)
      # via class-name guard so Smith doesn't require redis at load time.
      TRANSIENT_ERROR_NAMES = %w[
        Redis::BaseConnectionError
        Redis::TimeoutError
        Redis::CannotConnectError
        Redis::ConnectionError
      ].freeze

      def self.transient_errors
        TRANSIENT_ERROR_NAMES.filter_map do |name|
          Object.const_get(name)
        rescue NameError
          nil
        end + [Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EPIPE]
      end

      def initialize(redis:, namespace: "smith")
        @redis_source = redis
        @namespace = namespace.nil? ? nil : namespace.to_s.dup.freeze
      end

      def store(key, payload, ttl: Smith.config.persistence_ttl)
        Retry.with_retries(operation: :store, transient: self.class.transient_errors) do
          if ttl
            client.set(namespaced(key), payload, ex: ttl)
          else
            client.set(namespaced(key), payload)
          end
        end
      end

      def fetch(key)
        Retry.with_retries(operation: :fetch, transient: self.class.transient_errors) do
          client.get(namespaced(key))
        end
      end

      def delete(key)
        Retry.with_retries(operation: :delete, transient: self.class.transient_errors) do
          client.del(namespaced(key), namespaced_heartbeat(key))
        end
      end

      def transaction_open? = false

      def record_heartbeat(key, ttl: Smith.config.persistence_ttl)
        Retry.with_retries(operation: :record_heartbeat, transient: self.class.transient_errors) do
          iso = Time.now.utc.iso8601
          if ttl
            client.set(namespaced_heartbeat(key), iso, ex: ttl)
          else
            client.set(namespaced_heartbeat(key), iso)
          end
        end
      end

      def last_heartbeat(key)
        Retry.with_retries(operation: :last_heartbeat, transient: self.class.transient_errors) do
          raw = client.get(namespaced_heartbeat(key))
          next nil if raw.nil?

          Time.parse(raw).utc
        rescue ArgumentError
          nil
        end
      end

      # Optimistic locking via Redis WATCH/MULTI/EXEC. Raises
      # Smith::PersistenceVersionConflict on a stale expected_version
      # OR on EXEC failure (WATCH detected concurrent write).
      def store_versioned(key, payload, expected_version:, ttl: Smith.config.persistence_ttl)
        Retry.with_retries(operation: :store_versioned, transient: self.class.transient_errors) do
          namespaced_key = namespaced(key)
          result = client.watch(namespaced_key) do
            current = client.get(namespaced_key)
            if current && (current_version = parse_version(current)) != expected_version
              client.unwatch
              raise Smith::PersistenceVersionConflict.new(
                key: key, expected: expected_version, actual: current_version
              )
            end

            client.multi do |tx|
              if ttl
                tx.set(namespaced_key, payload, ex: ttl)
              else
                tx.set(namespaced_key, payload)
              end
            end
          end

          if result.nil?
            raise Smith::PersistenceVersionConflict.new(
              key: key, expected: expected_version, actual: :concurrent
            )
          end

          result
        end
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

      def namespaced_heartbeat(key)
        [@namespace, "heartbeat", key].compact.join(":")
      end

      def parse_version(payload)
        PayloadVersion.call(payload)
      end
    end
  end
end
