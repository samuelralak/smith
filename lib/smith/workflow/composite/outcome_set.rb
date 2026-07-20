# frozen_string_literal: true

require_relative "../../types"
require_relative "branch_outcome"

module Smith
  class Workflow
    module Composite
      class OutcomeSet < Dry::Struct
        attribute :ordered, Types::Array.of(Types.Instance(BranchOutcome))
        attribute :output, Types::Array.of(Types::Hash)

        def initialize(attributes)
          super
          ordered.freeze
          output.freeze
          self.attributes.freeze
          freeze
        end
      end
    end
  end
end
