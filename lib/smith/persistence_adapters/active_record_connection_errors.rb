# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    module ActiveRecordConnectionErrors
      NAMES = %w[
        ActiveRecord::ConnectionNotEstablished
        ActiveRecord::ConnectionFailed
        ActiveRecord::AdapterTimeout
      ].freeze

      module_function

      def classes
        NAMES.filter_map do |name|
          Object.const_get(name)
        rescue NameError
          nil
        end
      end
    end
  end
end
