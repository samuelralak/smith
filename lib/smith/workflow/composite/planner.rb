# frozen_string_literal: true

require "dry-initializer"

require_relative "branch"
require_relative "plan"

module Smith
  class Workflow
    module Composite
      class Planner
        extend Dry::Initializer

        option :dispatch
        option :kind
        option :transition
        option :from
        option :execution_namespace
        option :branch_specs
        option :input_digest
        option :budget_state_digest

        def call
          Plan.validate_branch_count!(branch_specs)
          Plan.build(
            dispatch:,
            kind:,
            transition:,
            from:,
            execution_namespace:,
            branches: build_branches,
            input_digest:,
            budget_state_digest:
          )
        end

        private

        def build_branches
          branch_specs.each_with_index.map do |spec, ordinal|
            Branch.build(
              ordinal:,
              key: spec.fetch(:key),
              agent: spec.fetch(:agent),
              binding_identity: spec.fetch(:binding_identity),
              budget: spec.fetch(:budget, {})
            )
          end.freeze
        end
      end
    end
  end
end
