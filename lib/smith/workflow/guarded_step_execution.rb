# frozen_string_literal: true

module Smith
  class Workflow
    module GuardedStepExecution
      private

      def run_guarded_step(transition)
        tracker = Tool::ExecutionTracker.new
        previous_tracker = Tool.current_tool_execution_tracker

        Thread.handle_interrupt(Object => :never) do
          Tool.current_tool_execution_tracker = tracker
          begin
            Thread.handle_interrupt(Object => :immediate) { run_tracked_guarded_step(transition) }
          rescue StandardError => e
            raise unless tracker.started?
            raise if terminal_retry_error?(e)

            raise ToolOutcomeUncertain.new(
              "transition failed after tool execution began; retry could replay an uncertain outcome"
            ), cause: e
          ensure
            Tool.current_tool_execution_tracker = previous_tracker
          end
        end
      end

      def run_tracked_guarded_step(transition)
        return apply_composite_reduction!(transition) if @composite_reduction

        @resolved_parallel_branch_count = preflight_branch_count(transition)
        run_standard_guarded_step(transition)
      ensure
        @resolved_parallel_branch_count = nil
      end
    end
  end
end
