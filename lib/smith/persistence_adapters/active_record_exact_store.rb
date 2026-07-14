# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    module ActiveRecordExactStore
      attr_reader :persistence_identity

      def replace_exact(key, payload, expected_payload:, ttl: nil) # rubocop:disable Lint/UnusedMethodArgument
        ensure_version_column!
        ensure_locking_configuration!
        model = model_class
        ensure_exact_schema!(model)
        ActiveRecordExactWrite.new(
          model: model,
          key_column: @key_column,
          payload_column: @payload_column,
          version_column: @version_column,
          key: key,
          payload: payload,
          expected_payload: expected_payload
        ).call
      rescue *ActiveRecordConnectionErrors.classes => e
        raise Smith::PersistenceIOError.new(operation: :replace_exact, cause: e)
      end

      private

      def ensure_exact_schema!(model)
        ensure_exact_payload_column!(model)
        ensure_exact_key_uniqueness!(model)
      end

      def ensure_exact_payload_column!(model)
        column = model.columns_hash.fetch(@payload_column.to_s)
        return if %i[string text].include?(column.type)

        raise ArgumentError,
              "ActiveRecordStore#replace_exact requires a text or string payload column on " \
              "#{model.table_name}.#{@payload_column}"
      end

      def ensure_exact_key_uniqueness!(model)
        connection = model.connection
        schema_cache = connection.schema_cache
        table_name = model.table_name
        key = @key_column.to_s
        return if schema_cache.primary_keys(table_name).to_s == key
        return if unconditional_unique_key_index?(schema_cache, table_name, key)

        raise ArgumentError,
              "ActiveRecordStore#replace_exact requires a unique database index on " \
              "#{table_name}.#{@key_column}"
      end

      def unconditional_unique_key_index?(schema_cache, table_name, key)
        schema_cache.indexes(table_name).any? do |index|
          index.unique && Array(index.columns).map(&:to_s) == [key] && index.where.to_s.empty?
        end
      end
    end
  end
end
