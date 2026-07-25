# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module BudgetEnforcement
      private

      def charge_tool_call!
        allowance = self.class.current_tool_call_allowance
        ledger = self.class.current_ledger
        workflow_active = ledger&.limits&.key?(:tool_calls)
        admission = CallAdmission.current

        return if admission&.claim(self)

        charge_agent_allowance!(allowance) { commit_workflow_tool_call!(ledger, workflow_active) }
      end

      def charge_agent_allowance!(allowance, &)
        return allowance.charge!(name, &) if allowance.is_a?(CallAllowance)
        return CallAllowance.charge_legacy!(allowance, &) if allowance.is_a?(Hash)

        yield
      end

      def commit_workflow_tool_call!(ledger, workflow_active)
        return unless workflow_active

        reservation = ledger.reserve!(:tool_calls, 1)
        ledger.reconcile!(reservation, 1)
      end

      def mark_tool_execution_started!
        self.class.current_tool_execution_tracker&.mark_started!
        self.class.__send__(:current_tool_dispatch_start_handler)&.call(self)
      end
    end
  end
end
