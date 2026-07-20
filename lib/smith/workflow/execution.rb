# frozen_string_literal: true

require_relative "agent_result"
require_relative "execution_binding_resolution"
require_relative "prepared_branch_execution"
require_relative "step_completion"
require_relative "step_context"

module Smith
  class Workflow
    module Execution
      include ExecutionBindingResolution
      include PreparedBranchExecution
      include StepCompletion
      include StepContext
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
        output = with_scoped_artifacts { run_with_retry_policy(transition) }
        StepCompletion.instance_method(:complete_step).bind_call(self, transition, output)
      end

      def setup_step_context
        Tool.current_deadline = wall_clock_deadline
        Tool.current_ledger = @ledger
        Tool.current_tool_result_collector = tool_result_collector
      end

      def run_guarded_step(transition)
        @resolved_parallel_branch_count = preflight_branch_count(transition)
        return dispatch_step(transition) if transition.deterministic?
        return run_guarded_fanout_step(transition) if transition.fanout?

        agent_class = resolve_agent_class(transition)
        run_input_guardrails(agent_class)
        apply_tool_guardrails(agent_class)
        prepared_input = build_session&.prepare!

        output = with_agent_context(agent_class) do
          dispatch_step(transition, prepared_input: prepared_input)
        end

        validate_data_volume!(output, agent_class)
        run_output_guardrails(output, agent_class)
        resolve_router_output(transition, output)
      ensure
        @resolved_parallel_branch_count = nil
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

        agent_class = resolve_agent_class(transition)
        # Accepts either static `model "id"` (chat_kwargs[:model]) OR
        # block-form `model { |ctx| ... }` (model_block). The block-form
        # path resolves the actual id in build_model_chain at attempt time.
        return nil unless agent_class.model_configured?

        invoke_agent(agent_class, prepared_input)
      end

      def execute_serial_step(transition, prepared_input: nil)
        Thread.current[:smith_last_agent_result] = nil
        clear_failed_billable_attempts
        ledger = effective_call_ledger
        reserved = reserve_for_serial(transition, ledger)
        begin
          result = execute_transition_body(transition, prepared_input: prepared_input)
          agent_result = result.is_a?(AgentResult) ? result : nil
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

      def resolve_agent_class(transition)
        parallel_binding = Thread.current[:smith_parallel_agent_binding]
        parallel_agent_class = parallel_binding&.resolve(workflow: self, transition:)
        return parallel_agent_class if parallel_agent_class

        transition.agent_name && resolve_registered_agent!(
          transition.agent_name,
          workflow_class: self.class,
          transition_name: transition.name,
          role: :agent
        )
      end
    end
  end
end
