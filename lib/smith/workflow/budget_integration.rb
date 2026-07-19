# frozen_string_literal: true

require_relative "agent_result"

module Smith
  class Workflow
    module BudgetIntegration
      TOKEN_DIMENSIONS = %i[total_tokens token_limit].freeze
      COST_DIMENSIONS = %i[total_cost].freeze
      BUDGET_DIMENSIONS = (TOKEN_DIMENSIONS + COST_DIMENSIONS).freeze
      AGENT_DIM_MAP = { token_limit: TOKEN_DIMENSIONS, cost: COST_DIMENSIONS }.freeze

      private

      def reserve_branch_budget(ledger, branch_estimates:)
        return nil unless ledger && branch_estimates

        reserve_estimates!(ledger, branch_estimates)
      end

      def compute_branch_estimates(ledger, branch_count:, agent_budget: nil)
        return nil unless ledger

        ledger.limits.each_with_object({}) do |(dim, _limit), est|
          per_branch = estimate_for_dimension(dim, ledger.remaining(dim), branch_count)
          cap = agent_cap_for_dimension(dim, agent_budget)
          est[dim] = cap ? [per_branch, cap].min : per_branch
        end
      end

      def reconcile_branch_budget(ledger, reservation, agent_result: nil)
        return unless ledger && reservation

        actuals = extract_actuals(agent_results_for_settlement(agent_result))
        settlement = reservation.amounts.to_h do |dimension, _amount|
          [dimension, actual_for_dimension(dimension, actuals[:tokens], actuals[:cost])]
        end
        return ledger.reconcile_many!(reservation, actual: settlement) if settlement.length > 1

        ledger.reconcile!(reservation, settlement.values.first)
      end

      def extract_actuals(agent_results)
        results = Array(agent_results).compact

        {
          tokens: results.sum { |result| (result.input_tokens || 0) + (result.output_tokens || 0) },
          cost: results.sum { |result| result.cost || 0 }
        }
      end

      def agent_results_for_settlement(agent_result = nil)
        [*failed_billable_attempts, agent_result].compact
      end

      def failed_billable_attempts
        Array(Thread.current[:smith_failed_agent_results])
      end

      def clear_failed_billable_attempts
        Thread.current[:smith_failed_agent_results] = []
      end

      def actual_for_dimension(dim, actual_tokens, actual_cost = 0)
        return actual_tokens if TOKEN_DIMENSIONS.include?(dim)
        return actual_cost if COST_DIMENSIONS.include?(dim)

        0
      end

      def release_branch_budget(ledger, reservation)
        return unless ledger && reservation

        return ledger.release_many!(reservation) if reservation.amounts.length > 1

        ledger.release!(reservation)
      end

      def settle_budget_on_failure(ledger, estimates, agent_result)
        return unless ledger && estimates

        if agent_result || failed_billable_attempts.any?
          reconcile_branch_budget(ledger, estimates, agent_result: agent_result)
        else
          release_branch_budget(ledger, estimates)
        end
      end

      def reserve_serial_budget(ledger, agent_budget: nil)
        return nil unless ledger

        estimates = ledger.limits.each_with_object({}) do |(dim, _limit), est|
          remaining = BUDGET_DIMENSIONS.include?(dim) ? ledger.remaining(dim) : 0
          cap = agent_cap_for_dimension(dim, agent_budget)
          est[dim] = cap ? [remaining, cap].min : remaining
        end

        reserve_estimates!(ledger, estimates)
      end

      def reserve_estimates!(ledger, estimates)
        return ledger.reserve_many!(estimates) if estimates.length > 1

        dimension, amount = estimates.first
        ledger.reserve!(dimension, amount)
      end

      def finalize_branch(transition, index, result, ledger, reserved)
        agent_result = result.is_a?(Workflow::AgentResult) ? result : nil
        reconcile_branch_budget(ledger, reserved, agent_result: agent_result)
        { branch: index, agent: transition.agent_name, output: agent_result ? agent_result.content : result }
      end

      def finalize_named_branch(branch_key, agent_name, result, ledger, reserved)
        agent_result = result.is_a?(Workflow::AgentResult) ? result : nil
        reconcile_branch_budget(ledger, reserved, agent_result: agent_result)
        { branch: branch_key, agent: agent_name, output: agent_result ? agent_result.content : result }
      end

      def estimate_for_dimension(dim, limit, branch_count)
        return 0 unless BUDGET_DIMENSIONS.include?(dim)

        TOKEN_DIMENSIONS.include?(dim) ? [limit / branch_count, 1].max : limit / branch_count
      end

      def agent_cap_for_dimension(dim, agent_budget)
        return nil unless agent_budget
        return agent_budget[dim] if agent_budget.key?(dim)

        AGENT_DIM_MAP.each do |agent_dim, workflow_dims|
          return agent_budget[agent_dim] if workflow_dims.include?(dim) && agent_budget.key?(agent_dim)
        end
        nil
      end
    end
  end
end
