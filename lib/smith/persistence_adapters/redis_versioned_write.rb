# frozen_string_literal: true

require "dry-initializer"

module Smith
  module PersistenceAdapters
    class RedisVersionedWrite
      extend Dry::Initializer

      option :client
      option :key
      option :storage_key
      option :payload
      option :expected_version
      option :ttl

      def call
        result = client.watch(storage_key) do
          current = client.get(storage_key)
          validate_current!(current)
          enqueue_write
        end
        return result unless result.nil?

        raise PersistenceVersionConflict.new(
          key: key,
          expected: expected_version,
          actual: :concurrent
        )
      end

      private

      def validate_current!(current)
        return VersionExpectation.validate_missing!(key, expected_version) unless current

        current_version = PayloadVersion.call(current)
        return if current_version == expected_version

        client.unwatch
        raise PersistenceVersionConflict.new(
          key: key,
          expected: expected_version,
          actual: current_version
        )
      end

      def enqueue_write
        client.multi do |transaction|
          options = ttl ? { ex: ttl } : {}
          transaction.set(storage_key, payload, **options)
        end
      end
    end
  end
end
