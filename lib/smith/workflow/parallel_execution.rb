# frozen_string_literal: true

require_relative "branch_env"
require_relative "parallel_agent_binding"
require_relative "thread_context_snapshot"

module Smith
  class Workflow
    module ParallelExecution
      NO_PARALLEL_BINDING = Object.new.freeze
      private_constant :NO_PARALLEL_BINDING

      private

      def execute_parallel_step(transition, prepared_input: nil)
        count = @resolved_parallel_branch_count || Parallel.resolve_branch_count(transition, @context)
        agent_class = resolve_agent_class(transition)
        estimates = compute_branch_estimates(@ledger, branch_count: count, agent_budget: agent_class&.budget)
        env = BranchEnv.new(
          prepared_input: prepared_input,
          guardrail_sources: Tool.current_guardrails,
          scoped_store: propagate_scoped_artifacts,
          branch_estimates: estimates,
          deadline: wall_clock_deadline,
          agent_class:
        )
        ledger = @ledger
        branches = Array.new(count) do |i|
          PreparedBranchExecution
            .instance_method(:prepared_branch)
            .bind_call(self, ParallelExecution.instance_method(:run_branch), transition, i, env, ledger)
        end
        Parallel.execute(branches: branches)
      end

      def run_branch(transition, index, env, ledger, signal)
        binding = ParallelAgentBinding.new(self, transition, env.agent_class)
        with_branch_context(env, ledger, parallel_agent_binding: binding) do
          with_agent_context(env.agent_class) do
            branch_ledger = effective_call_ledger
            reserved = reserve_branch_call(branch_ledger, env, ledger)
            begin
              result = guarded_branch_call(transition, env, signal)
              finalize_branch(transition, index, result, branch_ledger, reserved).tap { reserved = nil }
            ensure
              settle_budget_on_failure(branch_ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
            end
          end
        end
      end

      def reserve_branch_call(branch_ledger, env, workflow_ledger)
        return reserve_branch_budget(branch_ledger, branch_estimates: env.branch_estimates) if workflow_ledger

        reserve_serial_budget(branch_ledger) if branch_ledger
      end

      def with_branch_context(
        env,
        ledger,
        parallel_agent_binding: NO_PARALLEL_BINDING,
        agent_class: nil,
        &block
      )
        snapshot = ThreadContextSnapshot.new
        snapshot.around do
          if agent_class
            setup_fanout_branch_context(env, ledger, agent_class)
          else
            setup_branch_context(env, ledger)
          end
          unless parallel_agent_binding.equal?(NO_PARALLEL_BINDING)
            Thread.current[:smith_parallel_agent_binding] = parallel_agent_binding
          end
          Thread.handle_interrupt(Object => :immediate, &block)
        ensure
          teardown_branch_context(env)
        end
      end

      def setup_branch_context(env, ledger)
        env.setup_thread
        Tool.current_ledger = ledger
        Tool.current_tool_result_collector = tool_result_collector
        Thread.current[:smith_last_agent_result] = nil
        clear_failed_billable_attempts
      end

      def teardown_branch_context(env)
        Thread.current[:smith_last_agent_result] = nil
        clear_failed_billable_attempts
        Tool.current_ledger = nil
        Tool.current_tool_result_collector = nil
        Thread.current[:smith_parallel_agent_binding] = nil
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
        raise Parallel::Cancellation, "cancelled" if signal.cancelled?
      end
    end
  end
end
