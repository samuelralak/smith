# frozen_string_literal: true

require_relative "../../types"
require_relative "input"
require_relative "plan"

module Smith
  class Workflow
    module Composite
      class Preparation < Dry::Struct
        attribute :plan, Types.Instance(Plan)
        attribute :input, Types.Instance(Input)

        def initialize(attributes)
          super
          unless plan.input_digest == input.digest
            raise ArgumentError,
                  "composite preparation input does not match plan"
          end

          self.attributes.freeze
          freeze
        end
      end
    end
  end
end
