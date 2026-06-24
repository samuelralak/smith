# frozen_string_literal: true

require "monitor"

module Smith
  module PersistenceAdapters
    # In-process Hash adapter. Thread-safe via Monitor. No I/O, no
    # transient errors. Designed for tests and quick smoke runs.
    #
    # Tracks TTL via stamped expiry times so it behaves consistently with
    # other adapters' TTL semantics. Implements `store_versioned` via the
    # monitor, enabling optimistic-locking tests without Redis.
    #
    # Auto-selected by Smith.persistence_adapter when both
    # Smith.config.persistence_adapter is nil AND Smith.config.test_mode
    # is true (typically set in spec_helper.rb).
    class Memory
      def initialize
        @store = {}
        @heartbeats = {}
        @monitor = Monitor.new
      end

      def store(key, payload, ttl: Smith.config.persistence_ttl)
        @monitor.synchronize do
          @store[key] = { payload: payload, expires_at: ttl ? Time.now.utc + ttl : nil }
        end
      end

      def fetch(key)
        @monitor.synchronize do
          entry = @store[key]
          next nil if entry.nil?

          if entry[:expires_at] && entry[:expires_at] < Time.now.utc
            @store.delete(key)
            next nil
          end

          entry[:payload]
        end
      end

      def delete(key)
        @monitor.synchronize do
          @store.delete(key)
          @heartbeats.delete(key)
        end
      end

      def record_heartbeat(key, ttl: Smith.config.persistence_ttl)
        @monitor.synchronize do
          @heartbeats[key] = { at: Time.now.utc, expires_at: ttl ? Time.now.utc + ttl : nil }
        end
      end

      def last_heartbeat(key)
        @monitor.synchronize do
          entry = @heartbeats[key]
          next nil if entry.nil?

          if entry[:expires_at] && entry[:expires_at] < Time.now.utc
            @heartbeats.delete(key)
            next nil
          end

          entry[:at]
        end
      end

      # Optimistic locking via Monitor-synchronized version compare.
      # Raises Smith::PersistenceVersionConflict when the stored payload's
      # version differs from expected_version. The version is read from
      # the payload's JSON `persistence_version` field (same shape Redis
      # and ActiveRecord stores use, so the contract is consistent
      # across all versioned adapters).
      def store_versioned(key, payload, expected_version:, ttl: Smith.config.persistence_ttl)
        @monitor.synchronize do
          entry = @store[key]
          if entry
            current_version = parse_version(entry[:payload])
            if current_version != expected_version
              raise Smith::PersistenceVersionConflict.new(
                key: key, expected: expected_version, actual: current_version
              )
            end
          end
          @store[key] = { payload: payload, expires_at: ttl ? Time.now.utc + ttl : nil }
        end
      end

      def clear!
        @monitor.synchronize { @store.clear }
      end

      private

      def parse_version(payload)
        JSON.parse(payload).fetch("persistence_version", 0)
      rescue JSON::ParserError
        0
      end
    end
  end
end
