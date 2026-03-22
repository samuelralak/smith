# frozen_string_literal: true

module Smith
  class Workflow
    module BudgetIntegration
      TOKEN_DIMENSIONS = %i[total_tokens token_limit].freeze
      COST_DIMENSIONS = %i[total_cost].freeze
      BUDGET_DIMENSIONS = (TOKEN_DIMENSIONS + COST_DIMENSIONS).freeze

      private

      def reserve_branch_budget(ledger, branch_estimates:)
        return nil unless ledger && branch_estimates

        branch_estimates.each { |dim, amount| ledger.reserve!(dim, amount) }
        branch_estimates
      end

      def compute_branch_estimates(ledger, branch_count:)
        return nil unless ledger

        ledger.limits.each_with_object({}) do |(dim, _limit), est|
          est[dim] = estimate_for_dimension(dim, ledger.remaining(dim), branch_count)
        end
      end

      def reconcile_branch_budget(ledger, estimates, agent_result: nil)
        return unless ledger && estimates

        actuals = extract_actuals(agent_result)
        estimates.each do |dim, amt|
          ledger.reconcile!(dim, amt, actual_for_dimension(dim, actuals[:tokens], actuals[:cost]))
        end
      end

      def extract_actuals(agent_result)
        {
          tokens: (agent_result&.input_tokens || 0) + (agent_result&.output_tokens || 0),
          cost: agent_result&.cost || 0
        }
      end

      def actual_for_dimension(dim, actual_tokens, actual_cost = 0)
        return actual_tokens if TOKEN_DIMENSIONS.include?(dim)
        return actual_cost if COST_DIMENSIONS.include?(dim)

        0
      end

      def release_branch_budget(ledger, estimates)
        return unless ledger && estimates

        estimates.each { |dim, amount| ledger.release!(dim, amount) }
      end

      def settle_budget_on_failure(ledger, estimates, agent_result)
        return unless ledger && estimates

        if agent_result
          reconcile_branch_budget(ledger, estimates, agent_result: agent_result)
        else
          release_branch_budget(ledger, estimates)
        end
      end

      def reserve_serial_budget(ledger)
        return nil unless ledger

        estimates = ledger.limits.each_with_object({}) do |(dim, _limit), est|
          est[dim] = BUDGET_DIMENSIONS.include?(dim) ? ledger.remaining(dim) : 0
        end

        estimates.each { |dim, amount| ledger.reserve!(dim, amount) }
        estimates
      end

      def finalize_branch(transition, index, result, ledger, reserved)
        agent_result = result.is_a?(Workflow::AgentResult) ? result : nil
        reconcile_branch_budget(ledger, reserved, agent_result: agent_result)
        { branch: index, agent: transition.agent_name, output: agent_result ? agent_result.content : result }
      end

      def estimate_for_dimension(dim, limit, branch_count)
        return 0 unless BUDGET_DIMENSIONS.include?(dim)

        TOKEN_DIMENSIONS.include?(dim) ? [limit / branch_count, 1].max : limit / branch_count
      end
    end
  end
end
