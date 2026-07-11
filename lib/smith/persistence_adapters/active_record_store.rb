# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    class ActiveRecordStore
      # AR transient errors resolved via class-name guard so Smith
      # doesn't require activerecord at load time. Hosts that use this
      # adapter already have activerecord in their dep tree.
      def initialize(model:, key_column: :key, payload_column: :payload, version_column: :lock_version)
        @model_source = model.is_a?(String) ? model.dup.freeze : model
        @key_column = key_column
        @payload_column = payload_column
        @version_column = version_column
      end

      def store(key, payload, ttl: nil) # rubocop:disable Lint/UnusedMethodArgument
        # TTL is deferred for ActiveRecordStore — would require an
        # `expires_at` column + a periodic sweeper job. Ignored here;
        # documented as a known limitation.
        Retry.with_retries(operation: :store, transient: ActiveRecordConnectionErrors.classes) do
          record = model_class.find_or_initialize_by(@key_column => key)
          record.public_send(:"#{@payload_column}=", payload)
          record.save!
        end
      end

      def fetch(key)
        Retry.with_retries(operation: :fetch, transient: ActiveRecordConnectionErrors.classes) do
          model_class.find_by(@key_column => key)&.public_send(@payload_column)
        end
      end

      def delete(key)
        Retry.with_retries(operation: :delete, transient: ActiveRecordConnectionErrors.classes) do
          model_class.where(@key_column => key).delete_all
        end
      end

      def transaction_open?
        model_class.connection.transaction_open?
      end

      # Optimistic locking via Rails' built-in optimistic locking on the
      # `lock_version` column. Requires the AR model to have a
      # `lock_version` (or configured) integer column with default 0.
      # If absent, raises ArgumentError directing the host to migrate.
      def store_versioned(key, payload, expected_version:, ttl: nil) # rubocop:disable Lint/UnusedMethodArgument
        ensure_version_column!
        ensure_locking_configuration!

        write_versioned(key, payload, expected_version)
      rescue *ActiveRecordConnectionErrors.classes => e
        raise Smith::PersistenceIOError.new(operation: :store_versioned, cause: e)
      end

      private

      def ensure_version_column!
        return if model_class.column_names.include?(@version_column.to_s)

        raise ArgumentError,
              "ActiveRecordStore#store_versioned requires a #{@version_column} column on " \
              "#{model_class.name}. Add via: " \
              "add_column :#{model_class.table_name}, :#{@version_column}, :integer, default: 0"
      end

      def ensure_locking_configuration!
        locking_column = model_class.locking_column if model_class.respond_to?(:locking_column)
        locking_enabled = model_class.locking_enabled? if model_class.respond_to?(:locking_enabled?)
        return if locking_enabled && locking_column.to_s == @version_column.to_s

        raise ArgumentError,
              "ActiveRecordStore#store_versioned requires #{model_class.name}.locking_column " \
              "to be #{@version_column.inspect} with optimistic locking enabled"
      end

      def write_versioned(key, payload, expected_version)
        record = model_class.find_by(@key_column => key)
        return create_versioned_record(key, payload, expected_version) unless record

        validate_payload_version!(record, key, expected_version)
        record.public_send(:"#{@payload_column}=", payload)
        record.save!
      rescue ::ActiveRecord::StaleObjectError => e
        raise unless e.record.equal?(record)

        raise_concurrent_conflict(key, expected_version)
      end

      def create_versioned_record(key, payload, expected_version)
        created = ActiveRecordInitialWrite.call(
          model: model_class,
          key_column: @key_column,
          payload_column: @payload_column,
          key: key,
          payload: payload
        )
        return true if created

        raise_concurrent_conflict(key, expected_version)
      end

      def validate_payload_version!(record, key, expected_version)
        current_version = payload_version(record)
        return if current_version == expected_version

        raise Smith::PersistenceVersionConflict.new(
          key: key, expected: expected_version, actual: current_version
        )
      end

      def payload_version(record) = PayloadVersion.call(record.public_send(@payload_column))

      def raise_concurrent_conflict(key, expected_version)
        raise Smith::PersistenceVersionConflict.new(
          key: key, expected: expected_version, actual: :concurrent
        )
      end

      def model_class
        case @model_source
        when String
          Object.const_get(@model_source)
        else
          @model_source
        end
      rescue NameError => e
        raise ArgumentError, "ActiveRecord model #{@model_source.inspect} could not be resolved: #{e.message}"
      end
    end
  end
end
