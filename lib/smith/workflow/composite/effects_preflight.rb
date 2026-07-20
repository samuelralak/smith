# frozen_string_literal: true

require "bigdecimal"
require "dry-initializer"

require_relative "../../budget/decimal_context"
require_relative "../../budget/ledger"
require_relative "../prepared_step"
require_relative "../usage_entry"
require_relative "budget_math"
require_relative "effects_application"

module Smith
  class Workflow
    module Composite
      class EffectsPreflight
        extend Dry::Initializer

        option :effects
        option :baseline
        option :snapshotter

        def call
          next_total_tokens = total_tokens
          next_total_cost = total_cost
          next_usage = incoming_usage
          next_ledger = ledger
          next_tools = incoming_tools
          tool_results = baseline.tool_results + next_tools
          EffectsApplication.new(
            usage_entries: baseline.usage_entries + next_usage,
            tool_results:,
            total_tokens: next_total_tokens,
            total_cost: next_total_cost,
            ledger: next_ledger,
            baseline:
          )
        end

        private

        def incoming_usage
          @incoming_usage ||= effects.usage_entries.map { UsageEntry.from_h(_1) }.tap do |entries|
            known = baseline.usage_entries.to_h { [_1.usage_id, true] }
            raise WorkflowError, "composite usage entry was already applied" if
              entries.any? { known.key?(_1.usage_id) }
          end
        end

        def incoming_tools
          @incoming_tools ||= effects.tool_results.map do |entry|
            snapshotter.call(entry).transform_keys { _1.respond_to?(:to_sym) ? _1.to_sym : _1 }
          end
        end

        def total_tokens
          current = baseline.total_tokens
          raise WorkflowError, "workflow token total is invalid" unless current.is_a?(Integer) && current >= 0

          total = current + effects.total_tokens
          return total if total <= PreparedStep::MAX_COUNTER_VALUE

          raise WorkflowError, "workflow token total exceeds the signed 64-bit limit"
        end

        def total_cost
          current = baseline.total_cost
          unless current.is_a?(Numeric) && current.finite? && current >= 0
            raise WorkflowError, "workflow cost total is invalid"
          end

          total = Budget::DecimalContext.call do
            BigDecimal(current.to_s) + BigDecimal(effects.total_cost.to_s)
          end.to_f
          return total if total.finite?

          raise WorkflowError, "workflow cost total must be finite"
        end

        def ledger
          return baseline.ledger if effects.budget_consumed.empty?
          raise WorkflowError, "composite budget effects require a workflow ledger" unless baseline.ledger

          Budget::Ledger.new(
            limits: baseline.ledger.limits,
            consumed: combined_budget_consumed
          )
        end

        def combined_budget_consumed
          combined = BudgetMath
                     .sum([baseline.budget_consumed, effects.budget_consumed])
                     .transform_keys(&:to_sym)
          combined.each do |dimension, amount|
            raise BudgetExceeded if amount > baseline.ledger.limits.fetch(dimension)
          end
          combined
        end
      end
    end
  end
end
