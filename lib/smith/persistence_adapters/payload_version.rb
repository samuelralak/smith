# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    module PayloadVersion
      module_function

      def call(payload)
        document = payload.is_a?(String) ? JSON.parse(payload) : payload
        raise TypeError, "persisted workflow payload must be a JSON object" unless document.is_a?(Hash)

        version = document.fetch("persistence_version", 0)
        unless version.is_a?(Integer) && version >= 0
          raise TypeError, "persisted workflow persistence_version must be a non-negative integer"
        end

        version
      rescue JSON::ParserError
        0
      end
    end
  end
end
