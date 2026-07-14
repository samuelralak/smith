# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class IdentifierReference
        extend Dry::Initializer

        option :type
        option :identity
        option :label

        def initialize(...)
          super
          freeze
        end

        def hash
          [type, identity].hash
        end

        def eql?(other)
          other.is_a?(self.class) && type == other.type && identity == other.identity
        end
        alias == eql?

        def inspect = label
        def to_s = label
      end
    end
  end
end
