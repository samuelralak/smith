# frozen_string_literal: true

require "dry-initializer"

require_relative "active_record_exact_predicate"

module Smith
  module PersistenceAdapters
    class ActiveRecordExactWrite
      extend Dry::Initializer

      option :model
      option :key_column
      option :payload_column
      option :version_column
      option :key
      option :payload
      option :expected_payload

      def call
        updated = exact_scope.update_all(update_attributes)
        return payload if updated == 1

        raise PersistencePayloadConflict.new(key:)
      end

      private

      def exact_scope
        scope = model.where(key_column => key)
        ActiveRecordExactPredicate.new(model:, column: payload_column).call(scope, expected_payload)
      end

      def update_attributes
        lock = model.arel_table[version_column]
        { payload_column => payload, version_column => lock + 1 }
      end
    end
  end
end
