# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchAdmission
      extend Dry::Initializer

      option :calls
      option :context

      def call
        return if calls.empty? || bounded_completion_admits_calls?

        reservation = reserve
        return reservation if reservation
        return unless call_budget || workflow_budgeted?

        raise BudgetExceeded, "agent tool_calls budget exceeded"
      end

      private

      def reserve
        case call_budget
        when CallAllowance
          call_budget.reserve_batch(requested_tool_names, ledger:)
        when Hash
          LegacyCallAllowance.reserve_batch(call_budget, calls.length, ledger:)
        else
          reserve_workflow_budget
        end
      end

      def reserve_workflow_budget
        return unless workflow_budgeted?

        ledger_reservation = ledger.reserve!(:tool_calls, calls.length)
        CallReservation.new(limit: calls.length, ledger:, ledger_reservation:)
      end

      def bounded_completion_admits_calls?
        call_budget.is_a?(CallAllowance) && call_budget.complete_on_exhaustion?
      end

      def workflow_budgeted? = ledger&.limits&.key?(:tool_calls)

      def requested_tool_names = calls.map { _1.name.to_s }

      def call_budget = context.fetch(:current_tool_call_allowance)

      def ledger = context.fetch(:current_ledger)
    end
  end
end
