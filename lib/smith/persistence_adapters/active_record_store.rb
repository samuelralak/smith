# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    class ActiveRecordStore
      # AR transient errors resolved via class-name guard so Smith
      # doesn't require activerecord at load time. Hosts that use this
      # adapter already have activerecord in their dep tree.
      TRANSIENT_ERROR_NAMES = %w[
        ActiveRecord::ConnectionNotEstablished
        ActiveRecord::StatementInvalid
        ActiveRecord::TransactionIsolationConflict
      ].freeze

      def self.transient_errors
        TRANSIENT_ERROR_NAMES.filter_map do |name|
          Object.const_get(name)
        rescue NameError
          nil
        end
      end

      def initialize(model:, key_column: :key, payload_column: :payload, version_column: :lock_version)
        @model_source = model
        @key_column = key_column
        @payload_column = payload_column
        @version_column = version_column
      end

      def store(key, payload, ttl: nil) # rubocop:disable Lint/UnusedMethodArgument
        # TTL is deferred for ActiveRecordStore — would require an
        # `expires_at` column + a periodic sweeper job. Ignored here;
        # documented as a known limitation.
        Retry.with_retries(operation: :store, transient: self.class.transient_errors) do
          record = model_class.find_or_initialize_by(@key_column => key)
          record.public_send(:"#{@payload_column}=", payload)
          record.save!
        end
      end

      def fetch(key)
        Retry.with_retries(operation: :fetch, transient: self.class.transient_errors) do
          model_class.find_by(@key_column => key)&.public_send(@payload_column)
        end
      end

      def delete(key)
        Retry.with_retries(operation: :delete, transient: self.class.transient_errors) do
          model_class.where(@key_column => key).delete_all
        end
      end

      # Optimistic locking via Rails' built-in optimistic locking on the
      # `lock_version` column. Requires the AR model to have a
      # `lock_version` (or configured) integer column with default 0.
      # If absent, raises ArgumentError directing the host to migrate.
      def store_versioned(key, payload, expected_version:, ttl: nil) # rubocop:disable Lint/UnusedMethodArgument
        unless model_class.column_names.include?(@version_column.to_s)
          raise ArgumentError,
                "ActiveRecordStore#store_versioned requires a #{@version_column} column on " \
                "#{model_class.name}. Add via: " \
                "add_column :#{model_class.table_name}, :#{@version_column}, :integer, default: 0"
        end

        Retry.with_retries(operation: :store_versioned, transient: self.class.transient_errors) do
          record = model_class.find_or_initialize_by(@key_column => key)
          if record.persisted? && record.public_send(@version_column) != expected_version
            raise Smith::PersistenceVersionConflict.new(
              key: key, expected: expected_version, actual: record.public_send(@version_column)
            )
          end
          record.public_send(:"#{@payload_column}=", payload)
          record.save!
        rescue defined?(::ActiveRecord::StaleObjectError) ? ::ActiveRecord::StaleObjectError : StandardError => e
          raise unless defined?(::ActiveRecord::StaleObjectError) && e.is_a?(::ActiveRecord::StaleObjectError)

          raise Smith::PersistenceVersionConflict.new(
            key: key, expected: expected_version, actual: :concurrent
          )
        end
      end

      private

      def model_class
        @model_class ||= begin
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
end
