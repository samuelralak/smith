# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    module ActiveRecordInitialWrite
      module_function

      def call(model:, key_column:, payload_column:, key:, payload:)
        candidate = nil
        record = model.create_or_find_by!(key_column => key) do |new_record|
          candidate = new_record
          new_record.public_send(:"#{payload_column}=", payload)
        end

        created_record?(record, candidate)
      rescue ::ActiveRecord::RecordInvalid => e
        raise unless key_collision?(e.record, candidate, model, key_column, key)

        false
      rescue ::ActiveRecord::RecordNotFound => e
        raise e.cause if e.cause.is_a?(::ActiveRecord::RecordNotUnique)

        raise
      end

      def created_record?(record, candidate)
        return false unless record.equal?(candidate)
        return true if record.persisted?

        raise ::ActiveRecord::RecordNotSaved, "Active Record rolled back the workflow-state insert"
      end

      def key_collision?(record, candidate, model, key_column, key)
        record.equal?(candidate) &&
          record.errors.of_kind?(key_column, :taken) &&
          model.exists?(key_column => key)
      end

      private_class_method :created_record?, :key_collision?
    end
  end
end
