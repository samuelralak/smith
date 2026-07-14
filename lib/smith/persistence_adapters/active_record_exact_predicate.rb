# frozen_string_literal: true

require "dry-initializer"

module Smith
  module PersistenceAdapters
    class ActiveRecordExactPredicate
      extend Dry::Initializer

      option :model
      option :column

      def call(scope, expected_payload)
        scope.where(predicate, expected_payload)
      end

      private

      def predicate
        case connection.adapter_name.downcase
        when /postgres/
          "convert_to(#{qualified_column}, 'UTF8') = convert_to(?, 'UTF8')"
        when /sqlite/
          "CAST(#{qualified_column} AS BLOB) = CAST(? AS BLOB)"
        when /mysql|trilogy/
          "BINARY #{qualified_column} = BINARY ?"
        else
          raise ArgumentError,
                "ActiveRecordStore#replace_exact does not support byte-exact payload comparison for " \
                "#{connection.adapter_name.inspect}"
        end
      end

      def qualified_column
        table = connection.quote_table_name(model.table_name)
        attribute = connection.quote_column_name(column)
        "#{table}.#{attribute}"
      end

      def connection = model.connection
    end
  end
end
