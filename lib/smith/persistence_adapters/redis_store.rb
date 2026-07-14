# frozen_string_literal: true

require "time"

require_relative "redis_client_access"

module Smith
  module PersistenceAdapters
    class RedisStore
      include RedisClientAccess

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

      attr_reader :persistence_identity

      def initialize(redis:, namespace: "smith", identity: nil)
        @redis_source = redis
        @namespace = namespace.nil? ? nil : namespace.to_s.dup.freeze
        @persistence_identity = identity.to_s.dup.freeze if identity
        @client_resolution_mutex = Mutex.new
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
      def transaction_identity = nil

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
        without_reconnection do |redis|
          RedisVersionedWrite.new(
            client: redis,
            key: key,
            storage_key: namespaced(key),
            payload: payload,
            expected_version: expected_version,
            ttl: ttl
          ).call
        end
      rescue *self.class.transient_errors => e
        raise Smith::PersistenceIOError.new(operation: :store_versioned, cause: e)
      end

      def replace_exact(key, payload, expected_payload:, ttl: Smith.config.persistence_ttl)
        without_reconnection do |redis|
          RedisExactWrite.new(
            client: redis,
            key: key,
            storage_key: namespaced(key),
            payload: payload,
            expected_payload: expected_payload,
            ttl: ttl
          ).call
        end
      rescue *self.class.transient_errors => e
        raise Smith::PersistenceIOError.new(operation: :replace_exact, cause: e)
      end

      private

      def namespaced(key)
        [@namespace, key].compact.join(":")
      end

      def namespaced_heartbeat(key)
        [@namespace, "heartbeat", key].compact.join(":")
      end
    end
  end
end
