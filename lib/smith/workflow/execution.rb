# frozen_string_literal: true

module Smith
  class Workflow
    module Execution
      include Agent::Lifecycle
      include NestedExecution
      include EvaluatorOptimizer
      include OrchestratorWorker

      private

      def execute_step(transition)
        Tool.current_deadline = wall_clock_deadline
        output = with_scoped_artifacts { run_guarded_step(transition) }
        complete_step(transition, output)
      rescue StandardError => e
        handle_step_failure(transition, e)
        { transition: transition.name, from: transition.from, to: transition.to, error: e }
      ensure
        Tool.current_guardrails = nil
        Tool.current_deadline = nil
        Smith.scoped_artifacts = nil
      end

      def run_guarded_step(transition)
        agent_class = transition.agent_name ? Agent::Registry.find(transition.agent_name) : nil
        run_input_guardrails(agent_class)
        apply_tool_guardrails(agent_class)
        prepared_input = build_session&.prepare!

        output = dispatch_step(transition, prepared_input: prepared_input)

        validate_data_volume!(output, agent_class)
        run_output_guardrails(output, agent_class)
        resolve_router_output(transition, output)
      end

      def complete_step(transition, output)
        @state = transition.to
        @next_transition_name = @router_next_transition || transition.success_transition
        @router_next_transition = nil
        emit_step_completed(transition, output)
        { transition: transition.name, from: transition.from, to: transition.to, output: output }
      end

      def resolve_router_output(transition, output)
        return output unless transition.routed?

        @router_next_transition = Router.resolve(output, transition.router_config, workflow_class: self.class)
        nil # routed steps have no user-facing output
      end

      def execute_transition_body(transition, prepared_input: nil)
        @last_prepared_input = prepared_input
        return nil unless transition.agent_name

        agent_class = Agent::Registry.find(transition.agent_name)
        return nil unless agent_class
        return nil if agent_class.chat_kwargs[:model].nil?

        invoke_agent(agent_class, prepared_input)
      end

      def execute_serial_step(transition, prepared_input: nil)
        Thread.current[:smith_last_agent_result] = nil
        reserved = reserve_serial_budget(@ledger)
        begin
          result = execute_transition_body(transition, prepared_input: prepared_input)
          agent_result = result.is_a?(AgentResult) ? result : nil
          reconcile_branch_budget(@ledger, reserved, agent_result: agent_result)
          reserved = nil
          agent_result&.content || result
        ensure
          settle_budget_on_failure(@ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
          Thread.current[:smith_last_agent_result] = nil
        end
      end

      def execute_parallel_step(transition, prepared_input: nil)
        count = Parallel.resolve_branch_count(transition, @context)
        estimates = compute_branch_estimates(@ledger, branch_count: count)
        env = BranchEnv.new(
          prepared_input, Tool.current_guardrails, propagate_scoped_artifacts, estimates, wall_clock_deadline
        )
        ledger = @ledger
        branches = Array.new(count) { |i| proc { |signal| run_branch(transition, i, env, ledger, signal) } }
        Parallel.execute(branches: branches)
      end

      def run_branch(transition, index, env, ledger, signal)
        env.setup_thread
        Thread.current[:smith_last_agent_result] = nil
        reserved = reserve_branch_budget(ledger, branch_estimates: env.branch_estimates)
        begin
          result = guarded_branch_call(transition, env, signal)
          finalize_branch(transition, index, result, ledger, reserved).tap { reserved = nil }
        ensure
          settle_budget_on_failure(ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
          Thread.current[:smith_last_agent_result] = nil
          env.teardown_thread
        end
      end

      def guarded_branch_call(transition, env, signal)
        check_cancellation!(signal)
        check_deadline!
        result = execute_transition_body(transition, prepared_input: env.prepared_input)
        check_cancellation!(signal)
        result
      end

      def check_cancellation!(signal)
        raise Smith::WorkflowError, "cancelled" if signal.cancelled?
      end
    end
  end
end
