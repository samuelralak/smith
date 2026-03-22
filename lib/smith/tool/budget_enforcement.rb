# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module BudgetEnforcement
      private

      def charge_tool_call!
        allowance = self.class.current_tool_call_allowance
        ledger = self.class.current_ledger
        workflow_active = ledger&.limits&.key?(:tool_calls)

        check_agent_tool_calls!(allowance)
        commit_tool_call_charges!(ledger, allowance, workflow_active)
      end

      def check_agent_tool_calls!(allowance)
        return unless allowance

        raise BudgetExceeded, "agent tool_calls budget exceeded" if allowance[:remaining] <= 0
      end

      def commit_tool_call_charges!(ledger, allowance, workflow_active)
        if workflow_active
          ledger.reserve!(:tool_calls, 1)
          ledger.reconcile!(:tool_calls, 1, 1)
        end

        allowance[:remaining] -= 1 if allowance
      end
    end
  end
end
