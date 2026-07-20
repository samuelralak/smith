# frozen_string_literal: true

require "dry-initializer"

require_relative "../execution_result_snapshot"
require_relative "../message_value_normalizer"
require_relative "encoded_value_budget"
require_relative "outcome_set"
require_relative "value_budget"

module Smith
  class Workflow
    module Composite
      class OutcomeAccumulator
        extend Dry::Initializer

        ARRAY_EACH = Array.instance_method(:each)
        private_constant :ARRAY_EACH

        option :plan
        option :outcomes

        def call
          validate_array_count!
          initialize_accumulators
          each_outcome { insert!(_1) }
          complete_outcome_set
        end

        private

        def initialize_accumulators
          @seen = 0
          @ordered = Array.new(plan.branches.length)
          @output = Array.new(plan.branches.length)
          @effects_budget = value_budget(MessageValueNormalizer::MAX_BYTES, "composite aggregate effects")
          @encoded_effects_budget = EncodedValueBudget.new(
            max_bytes: MessageValueNormalizer::MAX_BYTES,
            label: "composite aggregate effects"
          )
          @output_budget = value_budget(ExecutionResultSnapshot::MAX_BYTES, "composite aggregate output")
          @encoded_output_budget = EncodedValueBudget.new(
            max_bytes: ExecutionResultSnapshot::MAX_BYTES,
            label: "composite aggregate output"
          )
          @output_budget.add(nil)
        end

        def complete_outcome_set
          raise ArgumentError, "composite outcomes are incomplete" unless @seen == plan.branches.length

          OutcomeSet.new(ordered: @ordered.freeze, output: @output.freeze)
        end

        def validate_array_count!
          return unless outcomes.is_a?(Array)
          return if Array.instance_method(:length).bind_call(outcomes) == plan.branches.length

          raise ArgumentError, "composite outcome count does not match plan"
        end

        def each_outcome(&)
          if outcomes.is_a?(Array)
            ARRAY_EACH.bind_call(outcomes, &)
          elsif outcomes.is_a?(Enumerator)
            outcomes.each(&)
          else
            raise ArgumentError, "composite outcomes must be an Array or Enumerator"
          end
        end

        def insert!(outcome)
          raise ArgumentError, "composite outcome count does not match plan" if @seen >= plan.branches.length

          branch = outcome_branch(outcome)
          validate_identity!(outcome, branch)
          raise ArgumentError, "composite outcome ordinal is duplicated" if @ordered[outcome.ordinal]

          output = output_entry(outcome, branch)
          add_to_budgets(outcome, output)
          store(outcome, output)
        end

        def outcome_branch(outcome)
          raise ArgumentError, "composite outcome must be typed" unless outcome.is_a?(BranchOutcome)

          plan.branches.fetch(outcome.ordinal) do
            raise ArgumentError, "composite outcome ordinal is invalid"
          end
        end

        def add_to_budgets(outcome, output)
          effects = outcome.effects.to_h
          @effects_budget.add(effects)
          @encoded_effects_budget.add(effects)
          @output_budget.add(output, depth: 1)
          @encoded_output_budget.add(output)
        end

        def store(outcome, output)
          @ordered[outcome.ordinal] = outcome
          @output[outcome.ordinal] = output
          @seen += 1
        end

        def validate_identity!(outcome, branch)
          valid = outcome.plan_digest == plan.plan_digest &&
                  outcome.branch_digest == branch.digest &&
                  outcome.branch_key == branch.key &&
                  outcome.agent == branch.agent
          raise ArgumentError, "composite outcome does not match its branch" unless valid
        end

        def output_entry(outcome, branch)
          branch_key = plan.kind == :parallel ? branch.ordinal : branch.key
          { "branch" => branch_key, "agent" => branch.agent, "output" => outcome.output }.freeze
        end

        def value_budget(max_bytes, label)
          result_budget = label == "composite aggregate output"
          ValueBudget.new(
            max_bytes:,
            max_nodes: result_budget ? ExecutionResultSnapshot::MAX_NODES : MessageValueNormalizer::MAX_NODES,
            max_depth: result_budget ? ExecutionResultSnapshot::MAX_DEPTH : MessageValueNormalizer::MAX_DEPTH,
            label:
          )
        end
      end
    end
  end
end
