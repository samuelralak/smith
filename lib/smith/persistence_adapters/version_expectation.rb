# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    module VersionExpectation
      module_function

      def validate_missing!(key, expected_version)
        return if expected_version.is_a?(Integer) && expected_version.zero?

        raise Smith::PersistenceVersionConflict.new(
          key: key,
          expected: expected_version,
          actual: :missing
        )
      end
    end
  end
end
