# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module BudgetEnforcement
      private

      def charge_tool_call!
        allowance = self.class.current_tool_call_allowance
        ledger = self.class.current_ledger
        workflow_active = ledger&.limits&.key?(:tool_calls)

        if allowance.is_a?(CallAllowance)
          return allowance.charge! { commit_workflow_tool_call!(ledger, workflow_active) }
        end
        if allowance.is_a?(Hash)
          return CallAllowance.charge_legacy!(allowance) { commit_workflow_tool_call!(ledger, workflow_active) }
        end

        commit_workflow_tool_call!(ledger, workflow_active)
      end

      def commit_workflow_tool_call!(ledger, workflow_active)
        return unless workflow_active

        reservation = ledger.reserve!(:tool_calls, 1)
        ledger.reconcile!(reservation, 1)
      end
    end
  end
end
