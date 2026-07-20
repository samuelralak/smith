# frozen_string_literal: true

module Smith
  class Workflow
    module Composite
      module FanoutBranchContract
        private

        def fanout_branch_specs(authorization, transition)
          branches = transition.fanout_config.fetch(:branches)
          count = branches.length
          Parallel.validate_branch_count!(count)
          validate_composite_branch_count!(count)
          allocator = composite_budget_allocator(count)
          branches.map.with_index do |(key, agent), ordinal|
            agent_class = captured_agent(authorization, transition, agent, :fanout_agent)
            fanout_branch_spec(key, agent, agent_class, allocator, ordinal)
          end.freeze
        end

        def fanout_branch_spec(key, agent, agent_class, allocator, ordinal)
          {
            key: key.to_s,
            agent: agent.to_s,
            binding_identity: composite_binding_identity!(agent_class, agent),
            budget: composite_branch_budget(allocator, ordinal, agent_class&.budget)
          }.freeze
        end

        def selected_fanout_branch_spec(authorization, execution, transition)
          branches = transition.fanout_config.fetch(:branches)
          Parallel.validate_branch_count!(branches.length)
          validate_selected_fanout_count!(branches, execution)

          agent = Transition
                  .instance_method(:fetch_fanout_agent!)
                  .bind_call(transition, execution.branch.key)
          agent_class = captured_agent(authorization, transition, agent, :fanout_agent)
          selected_fanout_spec(execution, agent, agent_class)
        end

        def validate_selected_fanout_count!(branches, execution)
          return if branches.length == execution.branch_count

          raise WorkflowError, "composite branch count does not match the prepared transition"
        end

        def selected_fanout_spec(execution, agent, agent_class)
          branch = execution.branch
          fanout_branch_spec(
            branch.key,
            agent,
            agent_class,
            composite_budget_allocator(execution.branch_count),
            branch.ordinal
          )
        end
      end
    end
  end
end
