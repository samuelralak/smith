# frozen_string_literal: true

module Smith
  class Workflow
    module ParallelExecution
      private

      def execute_parallel_step(transition, prepared_input: nil)
        count = Parallel.resolve_branch_count(transition, @context)
        agent_class = resolve_agent_class(transition)
        estimates = compute_branch_estimates(@ledger, branch_count: count, agent_budget: agent_class&.budget)
        env = BranchEnv.new(
          prepared_input, Tool.current_guardrails, propagate_scoped_artifacts, estimates, wall_clock_deadline
        )
        ledger = @ledger
        branches = Array.new(count) do |i|
          proc { |signal| run_branch(transition, i, env, ledger, signal) }
        end
        Parallel.execute(branches: branches)
      end

      def run_branch(transition, index, env, ledger, signal)
        setup_branch_context(env, ledger)
        with_agent_context(resolve_agent_class(transition)) do
          branch_ledger = effective_call_ledger
          reserved = reserve_branch_call(branch_ledger, env, ledger)
          begin
            result = guarded_branch_call(transition, env, signal)
            finalize_branch(transition, index, result, branch_ledger, reserved).tap { reserved = nil }
          ensure
            settle_budget_on_failure(branch_ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
          end
        end
      ensure
        teardown_branch_context(env)
      end

      def reserve_branch_call(branch_ledger, env, workflow_ledger)
        return reserve_branch_budget(branch_ledger, branch_estimates: env.branch_estimates) if workflow_ledger

        reserve_serial_budget(branch_ledger) if branch_ledger
      end

      def setup_branch_context(env, ledger)
        env.setup_thread
        Tool.current_ledger = ledger
        Thread.current[:smith_last_agent_result] = nil
      end

      def teardown_branch_context(env)
        Thread.current[:smith_last_agent_result] = nil
        Tool.current_ledger = nil
        env.teardown_thread
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
