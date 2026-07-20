# frozen_string_literal: true

require "dry-initializer"
require "json"

require_relative "../../errors"

module Smith
  class Workflow
    module Composite
      class EncodedValueBudget
        extend Dry::Initializer

        option :max_bytes
        option :label

        def initialize(...)
          super
          @bytes = 2
          @entries = 0
        end

        def add(value)
          @bytes += JSON.generate(value, max_nesting: false).bytesize
          @bytes += 1 if @entries.positive?
          @entries += 1
          raise WorkflowError, "#{label} exceeds maximum bytes #{max_bytes}" if @bytes > max_bytes

          self
        rescue JSON::GeneratorError => e
          raise WorkflowError, "#{label} cannot be encoded: #{e.message}"
        end
      end
    end
  end
end
