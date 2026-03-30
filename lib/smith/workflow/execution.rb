# frozen_string_literal: true

module Smith
  class Workflow
    module Execution
      include Agent::Lifecycle
      include NestedExecution
      include EvaluatorOptimizer
      include OrchestratorWorker
      include ParallelExecution
      include DeterministicExecution

      private

      def execute_step(transition)
        setup_step_context
        output = with_scoped_artifacts { run_guarded_step(transition) }
        complete_step(transition, output)
      rescue StandardError => e
        handle_step_failure(transition, e)
        { transition: transition.name, from: transition.from, to: transition.to, error: e }
      ensure
        teardown_step_context
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

      def run_guarded_step(transition)
        return dispatch_step(transition) if transition.deterministic?

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
      end

      def complete_step(transition, output)
        @state = transition.to
        @next_transition_name = @router_next_transition || transition.success_transition
        @router_next_transition = nil
        append_accepted_output(output)
        emit_step_completed(transition, output)
        { transition: transition.name, from: transition.from, to: transition.to, output: output }
      end

      def append_accepted_output(output)
        return unless @session_messages
        return if output.nil?

        @session_messages << { role: :assistant, content: output }
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
        return nil if agent_class.chat_kwargs[:model].nil?

        invoke_agent(agent_class, prepared_input)
      end

      def execute_serial_step(transition, prepared_input: nil)
        Thread.current[:smith_last_agent_result] = nil
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
        end
      end

      def reserve_for_serial(transition, ledger)
        agent_class = resolve_agent_class(transition)
        reserve_serial_budget(ledger, agent_budget: agent_class&.budget)
      end

      def resolve_agent_class(transition)
        return nil unless transition.agent_name

        Agent::Registry.fetch!(
          transition.agent_name,
          workflow_class: self.class,
          transition_name: transition.name,
          role: :agent
        )
      end
    end
  end
end
