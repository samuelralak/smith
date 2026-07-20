# frozen_string_literal: true

require_relative "../parallel"
require_relative "branch"
require_relative "branch_budget_contract"
require_relative "fanout_branch_contract"

module Smith
  class Workflow
    module Composite
      module BranchContract
        include BranchBudgetContract
        include FanoutBranchContract

        private

        def composite_branch_specs(authorization, transition, branch_count: nil)
          return parallel_branch_specs(authorization, transition, branch_count:) if transition.parallel?

          fanout_branch_specs(authorization, transition)
        end

        def parallel_branch_specs(authorization, transition, branch_count: nil)
          validate_planned_parallel_count!(transition, branch_count) if branch_count
          count = branch_count || Parallel.resolve_branch_count(transition, @context)
          validate_composite_branch_count!(count)
          agent = transition.agent_name
          agent_class = captured_agent(authorization, transition, agent, :agent)
          allocator = composite_budget_allocator(count)
          Array.new(count) do |ordinal|
            parallel_branch_spec(agent, agent_class, allocator, ordinal).merge(key: ordinal.to_s)
          end.freeze
        end

        def parallel_branch_spec(agent, agent_class, allocator, ordinal)
          {
            agent: agent.to_s,
            binding_identity: composite_binding_identity!(agent_class, agent),
            budget: composite_branch_budget(allocator, ordinal, agent_class&.budget)
          }.freeze
        end

        def validate_planned_parallel_count!(transition, branch_count)
          Parallel.validate_branch_count!(branch_count)
          configured = transition.agent_opts[:count]
          return if configured.respond_to?(:call)
          return if branch_count == (configured || 1)

          raise WorkflowError, "composite plan branch count does not match the prepared transition"
        end

        def captured_agent(authorization, transition, agent, role)
          authorization.fetch_agent!(
            agent,
            workflow_class: self.class,
            transition_name: transition.name,
            role:
          )
        end

        def validate_composite_branches!(authorization, plan, transition)
          specs = composite_branch_specs(authorization, transition, branch_count: plan.branches.length)
          specs.each_with_index do |spec, ordinal|
            expected = comparable_branch(Branch.build(ordinal:, **spec))
            actual = comparable_branch(plan.branches.fetch(ordinal))
            next if actual == expected

            raise WorkflowError, "composite plan branches do not match the prepared transition"
          end
        end

        def validate_composite_selected_branch!(authorization, execution, transition)
          branch = execution.branch
          spec = selected_branch_spec(authorization, execution, transition)
          candidate = Branch.build(ordinal: branch.ordinal, **spec)
          raise WorkflowError, "composite branch does not match the prepared transition" unless
            comparable_branch(candidate) == comparable_branch(branch)
        end

        def selected_branch_spec(authorization, execution, transition)
          return selected_parallel_branch_spec(authorization, execution, transition) if transition.parallel?

          selected_fanout_branch_spec(authorization, execution, transition)
        end

        def selected_parallel_branch_spec(authorization, execution, transition)
          branch = execution.branch
          count = execution.branch_count
          validate_planned_parallel_count!(transition, count)
          agent = transition.agent_name
          agent_class = captured_agent(authorization, transition, agent, :agent)
          allocator = composite_budget_allocator(count)
          parallel_branch_spec(agent, agent_class, allocator, branch.ordinal).merge(key: branch.ordinal.to_s)
        end

        def comparable_branch(branch)
          [branch.ordinal, branch.key, branch.agent, branch.binding_identity, branch.budget]
        end
      end
    end
  end
end
