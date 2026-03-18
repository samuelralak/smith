# frozen_string_literal: true

module Smith
  class Workflow
    module BudgetIntegration
      private

      def reserve_branch_budget(ledger)
        return nil unless ledger

        ledger.limits.each_key { |dim| ledger.reserve!(dim, 0) }
        ledger.limits.keys
      end

      def reconcile_branch_budget(ledger, dimensions)
        return unless ledger && dimensions

        dimensions.each { |dim| ledger.reconcile!(dim, 0, 0) }
      end

      def release_branch_budget(ledger, dimensions)
        return unless ledger && dimensions

        dimensions.each { |dim| ledger.release!(dim, 0) }
      end
    end
  end
end
