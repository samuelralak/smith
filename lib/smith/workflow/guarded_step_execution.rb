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
            raise unless uncertain_after_tools?(tracker, e)

            raise ToolOutcomeUncertain.new(
              "transition failed after tool execution began; retry could replay an uncertain outcome"
            ), cause: e
          ensure
            # Tool evidence travels up: a step running inside another step
            # (a nested workflow's step) marks the enclosing step too, so the
            # enclosing step is never retried over tools that already ran.
            previous_tracker&.mark_started! if tracker.started?
            Tool.current_tool_execution_tracker = previous_tracker
          end
        end
      end

      # A failure after a tool ran leaves its outcome uncertain, unless its
      # retry could not run the tool again: a terminal failure, or a tool
      # loop paused for budget, whose retry continues from its tools'
      # results.
      def uncertain_after_tools?(tracker, error)
        tracker.started? && !terminal_retry_error?(error) &&
          !(error.is_a?(BudgetUnavailable) && error.continuation)
      end

      def run_tracked_guarded_step(transition)
        return apply_composite_reduction!(transition) if @composite_reduction

        @resolved_parallel_branch_count = preflight_branch_count(transition)
        context_before = @context.dup
        output = run_standard_guarded_step(transition)
        enforce_context_shape!(context_before)
        output
      ensure
        @resolved_parallel_branch_count = nil
      end

      # Hooks that receive the live context (`before_eval`,
      # `after_completion`, guardrails) can write to it directly. At the end
      # of the step every new top-level key must be a Symbol that an explicit
      # `persist` list allows, and every new or replaced value takes the
      # context's key shape. On a violation the context goes back to its
      # top-level values from the start of the step, as a failed
      # deterministic step keeps none of its writes. A value changed in place
      # is not seen until the next restore normalizes it. `O(K)` plus the size
      # of changed values.
      def enforce_context_shape!(before)
        allowed = declared_persist_keys
        normalized = @context.each_with_object({}) do |(key, value), changed|
          next if before.key?(key) && before[key].equal?(value)

          admit_context_key!(key, new_key: !before.key?(key), allowed:)
          changed[key] = ContextKeys.normalize(value)
        end
        @context.merge!(normalized)
      rescue WorkflowError
        @context.replace(before)
        raise
      end

      def admit_context_key!(key, new_key:, allowed:)
        ContextKeys.validate_top_level_key!(key)
        return unless new_key && allowed && !allowed.include?(key)

        raise UndeclaredContextKey.new(key:, persisted_keys: allowed)
      end
    end
  end
end
