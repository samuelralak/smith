# frozen_string_literal: true

require_relative "branch_env"

module Smith
  class Workflow
    module FanoutExecution
      private

      def run_guarded_fanout_step(transition)
        branches = transition.fanout_config.fetch(:branches)
        branch_agent_classes = fanout_agent_classes(transition, branches)
        run_workflow_input_guardrails
        run_fanout_agent_input_guardrails(branch_agent_classes)
        prepared_input = build_session&.prepare!
        output = execute_fanout_step(
          transition,
          branches: branches,
          branch_agent_classes: branch_agent_classes,
          prepared_input: prepared_input
        )
        run_workflow_output_guardrails(output)
        output
      end

      def execute_fanout_step(transition, branches: nil, branch_agent_classes: nil, prepared_input: nil)
        branches ||= transition.fanout_config.fetch(:branches)
        branch_agent_classes ||= fanout_agent_classes(transition, branches)
        env = BranchEnv.new(
          prepared_input: prepared_input,
          guardrail_sources: nil,
          scoped_store: propagate_scoped_artifacts,
          branch_estimates: fanout_branch_estimates(branches, branch_agent_classes),
          deadline: wall_clock_deadline
        )

        branch_calls = branches.map do |branch_key, agent_name|
          PreparedBranchExecution.instance_method(:prepared_branch).bind_call(
            self,
            FanoutExecution.instance_method(:run_fanout_branch),
            branch_key,
            agent_name,
            branch_agent_classes.fetch(branch_key),
            env
          )
        end

        Parallel.execute(branches: branch_calls)
      end

      def run_fanout_branch(branch_key, agent_name, agent_class, env, signal)
        with_branch_context(env, @ledger, agent_class:) do
          with_agent_context(agent_class) do
            branch_ledger = effective_call_ledger
            reserved = reserve_fanout_branch_call(branch_ledger, env.branch_estimates[branch_key], agent_class)
            begin
              result = guarded_fanout_branch_call(agent_class, env, signal)
              finalize_named_branch(branch_key, agent_name, result, branch_ledger, reserved).tap { reserved = nil }
            ensure
              settle_budget_on_failure(branch_ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
            end
          end
        end
      end

      def guarded_fanout_branch_call(agent_class, env, signal)
        check_cancellation!(signal)
        check_deadline!
        result = agent_class.model_configured? ? invoke_agent(agent_class, env.prepared_input) : nil
        output = result.is_a?(AgentResult) ? result.content : result
        validate_data_volume!(output, agent_class)
        run_agent_output_guardrails(output, agent_class)
        check_cancellation!(signal)
        result
      end

      def setup_fanout_branch_context(env, ledger, agent_class)
        setup_branch_context(env, ledger)
        apply_tool_guardrails(agent_class)
      end

      def reserve_fanout_branch_call(branch_ledger, branch_estimates, agent_class)
        return reserve_branch_budget(branch_ledger, branch_estimates: branch_estimates) if @ledger

        reserve_serial_budget(branch_ledger, agent_budget: agent_class&.budget) if branch_ledger
      end

      def fanout_agent_classes(transition, branches)
        branches.to_h do |branch_key, agent_name|
          [branch_key, resolve_fanout_agent_class(transition, agent_name)]
        end
      end

      def run_fanout_agent_input_guardrails(branch_agent_classes)
        branch_agent_classes.each_value { |agent_class| run_agent_input_guardrails(agent_class) }
      end

      def fanout_branch_estimates(branches, branch_agent_classes)
        return {} unless @ledger

        branch_count = branches.length
        branches.each_with_object({}) do |(branch_key, _agent_name), map|
          agent_class = branch_agent_classes.fetch(branch_key)
          map[branch_key] = compute_branch_estimates(
            @ledger,
            branch_count: branch_count,
            agent_budget: agent_class&.budget
          )
        end
      end

      def resolve_fanout_agent_class(transition, agent_name)
        resolve_registered_agent!(
          agent_name,
          workflow_class: self.class,
          transition_name: transition&.name,
          role: :fanout_agent
        )
      end
    end
  end
end
