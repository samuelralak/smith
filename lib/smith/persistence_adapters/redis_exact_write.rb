# frozen_string_literal: true

require "dry-initializer"

module Smith
  module PersistenceAdapters
    class RedisExactWrite
      extend Dry::Initializer

      option :client
      option :key
      option :storage_key
      option :payload
      option :expected_payload
      option :ttl

      def call
        result = client.watch(storage_key) do
          validate_current!
          enqueue_write
        end
        return payload unless result.nil?

        raise PersistencePayloadConflict.new(key:)
      end

      private

      def validate_current!
        return if client.get(storage_key) == expected_payload

        client.unwatch
        raise PersistencePayloadConflict.new(key:)
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
