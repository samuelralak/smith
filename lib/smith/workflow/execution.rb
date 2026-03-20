# frozen_string_literal: true

module Smith
  class Workflow
    module Execution
      include Agent::Lifecycle

      private

      def execute_step(transition)
        agent_class = resolve_agent_class(transition)
        Tool.current_deadline = wall_clock_deadline
        output = with_scoped_artifacts { run_guarded_step(transition, agent_class) }
        complete_step(transition, output)
      rescue StandardError => e
        handle_step_failure(transition, e)
        { transition: transition.name, from: transition.from, to: transition.to, error: e }
      ensure
        Tool.current_guardrails = nil
        Tool.current_deadline = nil
        Smith.scoped_artifacts = nil
      end

      def run_guarded_step(transition, agent_class)
        run_input_guardrails(agent_class)
        apply_tool_guardrails(agent_class)
        session = build_session
        prepared_input = session&.prepare!

        output = if transition.parallel?
                   execute_parallel_step(transition, prepared_input: prepared_input)
                 else
                   execute_serial_step(transition, prepared_input: prepared_input)
                 end

        validate_data_volume!(output, agent_class)
        run_output_guardrails(output, agent_class)
        output
      end

      def complete_step(transition, output)
        @state = transition.to
        @next_transition_name = transition.success_transition
        emit_step_completed(transition, output)
        { transition: transition.name, from: transition.from, to: transition.to, output: output }
      end

      def resolve_agent_class(transition)
        return nil unless transition.agent_name

        Agent::Registry.find(transition.agent_name)
      end

      def execute_transition_body(transition, prepared_input: nil)
        @last_prepared_input = prepared_input

        return nil unless transition.agent_name

        agent_class = Agent::Registry.find(transition.agent_name)
        return nil unless agent_class
        return nil if agent_class.chat_kwargs[:model].nil?

        invoke_agent(agent_class, prepared_input)
      end

      def invoke_agent(agent_class, prepared_input)
        chat = agent_class.chat
        prepared_input&.each { |msg| chat.add_message(msg) }
        chat = chat.with_schema(agent_class.output_schema) if agent_class.output_schema

        check_deadline!
        response = chat.complete
        snapshot_and_finalize(agent_class, response)
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
        raise Smith::WorkflowError, "cancelled" if signal.cancelled?

        check_deadline!
        result = execute_transition_body(transition, prepared_input: env.prepared_input)
        raise Smith::WorkflowError, "cancelled" if signal.cancelled?

        result
      end
    end
  end
end
