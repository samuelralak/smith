# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    class ActiveRecordStore
      def initialize(model:, key_column: :key, payload_column: :payload)
        @model_source = model
        @key_column = key_column
        @payload_column = payload_column
      end

      def store(key, payload)
        record = model_class.find_or_initialize_by(@key_column => key)
        record.public_send(:"#{@payload_column}=", payload)
        record.save!
      end

      def fetch(key)
        model_class.find_by(@key_column => key)&.public_send(@payload_column)
      end

      def delete(key)
        model_class.where(@key_column => key).delete_all
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
