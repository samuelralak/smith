# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    module ActiveRecordExactStore
      # Child runs are stored under 64-character keys (digests).
      KEY_WIDTH = 64

      attr_reader :persistence_identity

      def replace_exact(key, payload, expected_payload:, ttl: nil)
        ensure_versioned_write!(ttl)
        model = model_class
        ensure_exact_schema!(model)
        ensure_plain_payload!(model)
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

      # Raises ArgumentError unless the model's table holds runs as their
      # writes need: the locking column, a text payload, and a string key the
      # database keeps unique, wide enough for child runs' keys (smith:doctor
      # reports it). Returns self.
      def check_schema!
        model = model_class
        ensure_version_column!
        ensure_locking_configuration!
        ensure_exact_schema!(model)
        ensure_key_column!(model)
        self
      end

      # Whether Rails encrypts the payload (`encrypts`): runs store and read
      # it, but replace_exact, which compares payloads in the database,
      # cannot.
      def encrypted_payload?
        model = model_class
        attributes = model.encrypted_attributes if model.respond_to?(:encrypted_attributes)
        Array(attributes).map(&:to_s).include?(@payload_column.to_s)
      end

      private

      def ensure_versioned_write!(ttl)
        PersistenceAdapters.refuse_active_record_ttl!(ttl)
        ensure_version_column!
        ensure_locking_configuration!
      end

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

      def ensure_key_column!(model)
        column = model.columns_hash.fetch(@key_column.to_s)
        return if %i[string text].include?(column.type) && (column.limit.nil? || column.limit >= KEY_WIDTH)

        raise ArgumentError,
              "ActiveRecordStore requires #{model.table_name}.#{@key_column} to be a string or text column of at " \
              "least #{KEY_WIDTH} characters: child runs are stored under #{KEY_WIDTH}-character keys"
      end

      def ensure_plain_payload!(model)
        return unless encrypted_payload?

        raise ArgumentError,
              "ActiveRecordStore#replace_exact compares payloads in the database, so it cannot use " \
              "#{model.name}'s encrypted #{@payload_column}"
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
