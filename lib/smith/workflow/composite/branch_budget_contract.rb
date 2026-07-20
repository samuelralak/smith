# frozen_string_literal: true

require_relative "budget_allocator"
require_relative "plan"

module Smith
  class Workflow
    module Composite
      module BranchBudgetContract
        private

        def validate_composite_branch_count!(count)
          Plan.validate_branch_count!(count)
        end

        def composite_budget_allocator(branch_count)
          return unless @ledger

          BudgetAllocator.new(ledger: @ledger, branch_count:)
        end

        def composite_branch_budget(allocator, ordinal, agent_budget)
          return {} unless allocator

          caps = @ledger.limits.each_key.with_object({}) do |dimension, result|
            cap = agent_cap_for_dimension(dimension, agent_budget)
            result[dimension] = cap unless cap.nil?
          end
          allocator.call(ordinal:, caps:)
        end

        def composite_binding_identity!(agent_class, agent)
          identity = agent_class&.execution_identity
          return identity if identity

          raise WorkflowError, "durable composite agent :#{agent} requires an execution_identity"
        end
      end
    end
  end
end
