# frozen_string_literal: true

require "monitor"
require "securerandom"

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
      attr_reader :persistence_identity

      def initialize(identity: "memory:#{SecureRandom.uuid}")
        @persistence_identity = identity.to_s.dup.freeze
        @store = {}
        @heartbeats = {}
        @monitor = Monitor.new
      end

      def store(key, payload, ttl: Smith.config.persistence_ttl)
        @monitor.synchronize do
          @store[key] = entry_for(payload, ttl)
        end
      end

      def fetch(key)
        @monitor.synchronize do
          entry = live_entry(key)
          next nil if entry.nil?

          copy_payload(entry[:payload])
        end
      end

      def delete(key)
        @monitor.synchronize do
          @store.delete(key)
          @heartbeats.delete(key)
        end
      end

      def transaction_open? = false
      def transaction_identity = nil

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
          entry = live_entry(key)
          if entry
            current_version = parse_version(entry[:payload])
            if current_version != expected_version
              raise Smith::PersistenceVersionConflict.new(
                key: key, expected: expected_version, actual: current_version
              )
            end
          else
            VersionExpectation.validate_missing!(key, expected_version)
          end
          @store[key] = entry_for(payload, ttl)
        end
      end

      def replace_exact(key, payload, expected_payload:, ttl: Smith.config.persistence_ttl)
        @monitor.synchronize do
          entry = live_entry(key)
          raise PersistencePayloadConflict.new(key:) unless entry && entry[:payload] == expected_payload

          @store[key] = entry_for(payload, ttl)
        end
        payload
      end

      def clear!
        @monitor.synchronize { @store.clear }
      end

      private

      def live_entry(key)
        entry = @store[key]
        return unless entry
        return entry unless entry[:expires_at] && entry[:expires_at] < Time.now.utc

        @store.delete(key)
        nil
      end

      def entry_for(payload, ttl)
        { payload: copy_payload(payload), expires_at: ttl ? Time.now.utc + ttl : nil }
      end

      def copy_payload(payload)
        payload.dup
      rescue TypeError
        payload
      end

      def parse_version(payload)
        PayloadVersion.call(payload)
      end
    end
  end
end
