# frozen_string_literal: true

require_relative "../composite/contract"
require_relative "composite_branch_effects"
require_relative "composite_branch_outcome"

module Smith
  class Workflow
    module SplitStepPersistence
      module CompositeBranchExecution
        include Composite::Contract
        include CompositeBranchEffects
        include CompositeBranchOutcome

        private

        def execute_authorized_composite_branch!(authorization, execution:, input:)
          authorization = validate_composite_authorization!(authorization)
          perform_authorized_prepared_step_execution!(authorization) do
            validate_composite_branch_execution!(authorization, execution, input)
            [nil, execute_composite_branch(authorization, execution, input)]
          end
        end

        def execute_composite_branch(authorization, execution, input)
          branch = execution.branch
          previous_ledger = @ledger
          previous_execution_namespace = @execution_namespace
          @ledger = composite_branch_ledger(branch)
          @execution_namespace = execution.execution_namespace
          offsets = composite_effect_offsets
          output, error = capture_composite_branch do
            dispatch_composite_branch(authorization, execution, input)
          end
          effects, effect_error = capture_composite_branch_effects(*offsets, branch)
          composite_branch_outcome(execution, output, error || effect_error, effects)
        ensure
          @ledger = previous_ledger
          @execution_namespace = previous_execution_namespace
        end

        def capture_composite_branch(&block)
          output = within_raw_step_context { with_scoped_artifacts(&block) }
          [output, nil]
        rescue StandardError => e
          [nil, e]
        end

        def dispatch_composite_branch(authorization, execution, input)
          branch = execution.branch
          transition = @split_step_transition
          agent_role = execution.kind == :parallel ? :agent : :fanout_agent
          agent_class = captured_agent(authorization, transition, branch.agent, agent_role)
          apply_tool_guardrails(agent_class) if execution.kind == :parallel
          environment = composite_branch_environment(execution, input, agent_class, transition)
          execute_composite_branch_kind(execution, transition, agent_class, environment)
        end

        def execute_composite_branch_kind(execution, transition, agent_class, environment)
          branch = execution.branch
          signal = Parallel::CancellationSignal.new
          return run_branch(transition, branch.ordinal, environment, @ledger, signal) if execution.kind == :parallel

          branch_key, agent = fetch_composite_fanout_branch(transition, branch.key)
          run_fanout_branch(branch_key, agent, agent_class, environment, signal)
        end

        def composite_branch_environment(execution, input, agent_class, transition)
          branch = execution.branch
          budget = branch.budget.transform_keys(&:to_sym)
          branch_key = fetch_composite_fanout_branch(transition, branch.key).first unless execution.kind == :parallel
          estimates = execution.kind == :parallel ? budget : { branch_key => budget }
          BranchEnv.new(
            prepared_input: input.agent_messages,
            guardrail_sources: Tool.current_guardrails,
            scoped_store: propagate_scoped_artifacts,
            branch_estimates: estimates,
            deadline: wall_clock_deadline,
            agent_class: execution.kind == :parallel ? agent_class : nil
          )
        end

        def composite_branch_ledger(branch)
          return if branch.budget.empty?

          Budget::Ledger.new(limits: branch.budget.transform_keys(&:to_sym))
        end

        def fetch_composite_fanout_branch(transition, branch_key)
          Transition.instance_method(:fetch_fanout_branch!).bind_call(transition, branch_key)
        end
      end
    end
  end
end
