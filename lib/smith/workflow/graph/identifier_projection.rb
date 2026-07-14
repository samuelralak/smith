# frozen_string_literal: true

require_relative "identifier_reference"

module Smith
  class Workflow
    class Graph
      class IdentifierProjection
        IMMUTABLE_SCALARS = [Symbol, Integer, TrueClass, FalseClass, NilClass].freeze

        def initialize
          @references = {}.compare_by_identity
        end

        def call(value)
          return value.dup.freeze if value.is_a?(String)
          return value if IMMUTABLE_SCALARS.any? { value.is_a?(_1) }

          @references[value] ||= IdentifierReference.new(
            type: value.class.name.to_s.dup.freeze,
            identity: value.object_id,
            label: label_for(value)
          )
        end

        private

        def label_for(value)
          value.inspect.dup.freeze
        rescue StandardError
          "#<#{value.class}:#{value.object_id}>".freeze
        end
      end
    end
  end
end
