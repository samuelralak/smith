# frozen_string_literal: true

require "dry-initializer"

require_relative "branch_outcome"
require_relative "budget_math"
require_relative "effects"
require_relative "outcome_accumulator"
require_relative "plan"
require_relative "reduction"

module Smith
  class Workflow
    module Composite
      class Reducer
        extend Dry::Initializer

        option :plan
        option :outcomes
        option :primary_failure, optional: true

        def call
          outcome_set = OutcomeAccumulator.new(plan:, outcomes:).call
          ordered = outcome_set.ordered
          validate_effects!(ordered)
          effects = merged_effects(ordered)
          failure_seen, selected_failure = failure_state(ordered)
          return successful_reduction(outcome_set.output, effects) unless failure_seen

          failed_reduction(selected_failure, effects)
        end

        private

        def validate_effects!(ordered)
          usage_ids = {}
          ordered.each { validate_outcome_effects!(_1, usage_ids) }
        end

        def validate_outcome_effects!(outcome, usage_ids)
          branch = plan.branches.fetch(outcome.ordinal)
          validate_budget!(outcome.effects, branch.budget)
          validate_usage!(outcome.effects.usage_entries, branch, usage_ids)
        end

        def validate_usage!(entries, branch, usage_ids)
          entries.each { validate_usage_entry!(_1, branch, usage_ids) }
        end

        def validate_usage_entry!(entry, branch, usage_ids)
          unless entry.fetch("agent_name") == branch.agent
            raise ArgumentError, "composite usage entry does not match its branch agent"
          end

          usage_id = entry.fetch("usage_id")
          raise ArgumentError, "composite usage entry is duplicated" if usage_ids.key?(usage_id)

          usage_ids[usage_id] = true
        end

        def validate_budget!(effects, envelope)
          consumed = effects.budget_consumed
          validate_budget_dimensions!(consumed, envelope)
          envelope.each { |dimension, limit| validate_budget_dimension!(dimension, limit, consumed, effects) }
        end

        def validate_budget_dimensions!(consumed, envelope)
          return if (consumed.keys - envelope.keys).empty?

          raise ArgumentError, "composite branch consumed an undeclared budget dimension"
        end

        def validate_budget_dimension!(dimension, limit, consumed, effects)
          amount = consumed.fetch(dimension, 0)
          unless amount.is_a?(Numeric) && amount.finite? && amount >= 0 && amount <= limit
            raise ArgumentError, "composite branch budget consumption exceeds its envelope"
          end

          expected = expected_consumption(dimension, effects)
          return if decimal_equal?(amount, expected)

          raise ArgumentError, "composite branch budget consumption does not match recorded usage"
        end

        def expected_consumption(dimension, effects)
          return effects.total_tokens if %w[total_tokens token_limit].include?(dimension)
          return effects.total_cost if dimension == "total_cost"

          0
        end

        def decimal_equal?(left, right)
          Budget::DecimalContext.call { BigDecimal(left.to_s) == BigDecimal(right.to_s) }
        end

        def merged_effects(ordered)
          Effects.new(
            usage_entries: ordered.flat_map { _1.effects.usage_entries },
            tool_results: ordered.flat_map { _1.effects.tool_results },
            budget_consumed: BudgetMath.sum(ordered.map { _1.effects.budget_consumed })
          )
        end

        def failure_state(ordered)
          expected_key = primary_failure&.to_s
          failure_seen = false
          selected_failure = nil
          ordered.each do |outcome|
            next unless outcome.failed?

            failure_seen = true
            selected_failure = outcome if outcome.branch_key == expected_key
          end
          [failure_seen, selected_failure]
        end

        def successful_reduction(output, effects)
          raise ArgumentError, "primary failure must be absent for a successful composite" if primary_failure

          Reduction.new(status: :succeeded, output:, error: nil,
                        failed_branch_key: nil, effects:)
        end

        def failed_reduction(failure, effects)
          raise ArgumentError, "primary failure must identify a failed branch" unless failure

          Reduction.new(status: :failed, output: nil, error: failure.error,
                        failed_branch_key: failure.branch_key, effects:)
        end
      end
    end
  end
end
