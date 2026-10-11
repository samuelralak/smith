# frozen_string_literal: true

require_relative "agent_result"
require_relative "execution_binding_resolution"
require_relative "guarded_step_execution"
require_relative "prepared_branch_execution"
require_relative "step_completion"
require_relative "step_context"
require_relative "step_stream"

module Smith
  class Workflow
    module Execution
      include ExecutionBindingResolution
      include GuardedStepExecution
      include PreparedBranchExecution
      include StepCompletion
      include StepContext
      include StepStream
      include Agent::Lifecycle
      include NestedExecution
      include EvaluatorOptimizer
      include OrchestratorWorker
      include ParallelExecution
      include FanoutExecution
      include RetryExecution
      include DeterministicExecution

      private

      def execute_step(transition)
        with_step_context(transition) { execute_step_body(transition) }
      end

      def execute_step_body(transition)
        # Reset the per-step agent-attribution carrier so only a serial agent
        # step that actually runs (below) leaves model/provider for complete_step;
        # a deterministic step never sets it and must not inherit a stale value.
        # The optimizer's verdict carrier resets for the same reason.
        @pending_agent_execution = nil
        @pending_evaluations = nil
        writable_output_key!(transition) if transition.output_to
        with_step_stream(transition) do
          output = with_scoped_artifacts { run_with_retry_policy(transition) }
          output = queue_batch(transition, output) if output.is_a?(BatchExecution::Captured)
          next output if wait_pending?(output)

          StepCompletion.instance_method(:complete_step).bind_call(self, transition, output)
        end
      end

      # Restored with the step's thread context (ThreadContextSnapshot): a
      # step's depth counts the runs whose steps it runs inside.
      def setup_step_context
        Thread.current[:smith_step_depth] = (Thread.current[:smith_step_depth] || 0) + 1
        Tool.current_deadline = wall_clock_deadline
        Tool.current_ledger = @ledger
        Tool.current_tool_result_collector = tool_result_collector
      end

      # An await, delay, map or call waits; a spawn launches and continues.
      def execute_waiting_step(transition)
        transition.spawns? ? execute_spawn_step(transition) : execute_await_step(transition)
      end

      def run_standard_guarded_step(transition)
        return execute_waiting_step(transition) if transition.awaits? || transition.spawns?
        return dispatch_step(transition) if transition.deterministic?
        return run_guarded_fanout_step(transition) if transition.fanout?

        agent_class = resolve_agent_class(transition)
        run_input_guardrails(agent_class)
        apply_tool_guardrails(agent_class)
        prepared_input = step_prepared_input(transition)
        return send_agent_batch(transition, agent_class, prepared_input) if batch_send?(transition)

        guarded_agent_output(transition, agent_class, prepared_input)
      end

      def guarded_agent_output(transition, agent_class, prepared_input)
        output = with_agent_context(agent_class) do
          dispatch_step(transition, prepared_input: prepared_input)
        end

        validate_data_volume!(output, agent_class)
        run_output_guardrails(output, agent_class)
        resolve_router_output(transition, output)
      end

      def preflight_branch_count(transition)
        return Parallel.validate_branch_count!(transition.fanout_config.fetch(:branches).length) if transition.fanout?

        Parallel.resolve_branch_count(transition, @context) if transition.parallel?
      end

      def resolve_router_output(transition, output)
        return output unless transition.routed?

        @router_next_transition = Router.resolve(output, transition.router_config, workflow_class: self.class)
        nil # routed steps have no user-facing output
      end

      def execute_transition_body(transition, prepared_input: nil)
        @last_prepared_input = prepared_input
        return nil unless transition.agent_name

        # An agent with no model and no fallback models fails in
        # complete_with_provider rather than skipping the step.
        invoke_agent(resolve_agent_class(transition), prepared_input)
      end

      def execute_serial_step(transition, prepared_input: nil)
        Thread.current[:smith_last_agent_result] = nil
        clear_failed_billable_attempts
        ledger = effective_call_ledger
        reserved = reserve_for_serial(transition, ledger)
        begin
          result = execute_transition_body(transition, prepared_input: prepared_input)
          agent_result = result.is_a?(AgentResult) ? result : nil
          # Capture the model/provider that actually served this serial agent
          # step (post fallback resolution) for complete_step to fold into the
          # durable step record. Nil when no agent ran (e.g. unconfigured model).
          @pending_agent_execution = agent_result && { model: agent_result.model_used, provider: agent_result.provider_used }
          reconcile_branch_budget(ledger, reserved, agent_result: agent_result)
          reserved = nil
          agent_result ? agent_result.content : result
        ensure
          settle_budget_on_failure(ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
          Thread.current[:smith_last_agent_result] = nil
          clear_failed_billable_attempts
        end
      end

      def reserve_for_serial(transition, ledger)
        agent_class = resolve_agent_class(transition)
        reserve_serial_budget(ledger, agent_budget: agent_class&.budget)
      end
    end
  end
end
