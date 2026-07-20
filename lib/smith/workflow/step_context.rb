# frozen_string_literal: true

require_relative "thread_context_snapshot"

module Smith
  class Workflow
    module StepContext
      private

      def with_step_context(transition, &block)
        ThreadContextSnapshot.new.around do
          setup_step_context
          Thread.handle_interrupt(Object => :immediate, &block)
        rescue StandardError => e
          @outcome = nil
          GuardrailIntegration.instance_method(:handle_step_failure).bind_call(self, transition, e)
        ensure
          teardown_step_context
        end
      end

      def setup_step_context
        Tool.current_deadline = wall_clock_deadline
        Tool.current_ledger = @ledger
        Tool.current_tool_result_collector = tool_result_collector
      end

      def teardown_step_context
        Tool.current_guardrails = nil
        Tool.current_deadline = nil
        Tool.current_ledger = nil
        Tool.current_tool_result_collector = nil
        Smith.scoped_artifacts = nil
      end
    end
  end
end
