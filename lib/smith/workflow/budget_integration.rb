# frozen_string_literal: true

module Smith
  class Workflow
    module BudgetIntegration
      TOKEN_DIMENSIONS = %i[total_tokens token_limit].freeze

      private

      def reserve_branch_budget(ledger, branch_count:)
        return nil unless ledger

        estimates = ledger.limits.each_with_object({}) do |(dim, limit), est|
          est[dim] = estimate_for_dimension(dim, limit, branch_count)
        end

        estimates.each { |dim, amount| ledger.reserve!(dim, amount) }
        estimates
      end

      def reconcile_branch_budget(ledger, estimates, agent_result: nil)
        return unless ledger && estimates

        actual_tokens = (agent_result&.input_tokens || 0) + (agent_result&.output_tokens || 0)
        estimates.each { |dim, amt| ledger.reconcile!(dim, amt, actual_for_dimension(dim, actual_tokens)) }
      end

      def actual_for_dimension(dim, actual_tokens)
        if TOKEN_DIMENSIONS.include?(dim) then actual_tokens
        elsif dim == :tool_calls then 1
        else 0
        end
      end

      def release_branch_budget(ledger, estimates)
        return unless ledger && estimates

        estimates.each { |dim, amount| ledger.release!(dim, amount) }
      end

      def estimate_for_dimension(dim, limit, branch_count)
        if TOKEN_DIMENSIONS.include?(dim)
          limit / branch_count
        elsif dim == :tool_calls
          1
        else
          0
        end
      end
    end
  end
end
