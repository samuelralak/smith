# frozen_string_literal: true

require_relative "../../types"
require_relative "../../budget/ledger"
require_relative "../usage_entry"

module Smith
  class Workflow
    module Composite
      class EffectsBaseline < Dry::Struct
        NumericType = Types::Integer | Types::Float
        private_constant :NumericType

        attribute :usage_entries, Types::Array.of(Types.Instance(UsageEntry))
        attribute :tool_results, Types::Array.of(Types::Hash)
        attribute :total_tokens, Types::Integer
        attribute :total_cost, NumericType
        attribute :ledger, Types.Instance(Budget::Ledger).optional
        attribute :budget_consumed, Types::Hash

        def initialize(attributes)
          super
          unless total_tokens >= 0 && total_cost.finite? && total_cost >= 0
            raise ArgumentError, "composite effects baseline totals are invalid"
          end

          usage_entries.freeze
          tool_results.freeze
          budget_consumed.freeze
          self.attributes.freeze
          freeze
        end
      end
    end
  end
end
