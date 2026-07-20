# frozen_string_literal: true

require_relative "../composite/effects"

module Smith
  class Workflow
    module SplitStepPersistence
      module CompositeBranchEffects
        private

        def composite_effect_offsets
          usage = @usage_mutex.synchronize { @usage_entries.length }
          tools = @tool_results_mutex.synchronize { @tool_results.length }
          [usage, tools]
        end

        def capture_composite_branch_effects(usage_offset, tool_offset, branch)
          usage = @usage_mutex.synchronize do
            @usage_entries.drop(usage_offset).map { composite_usage_entry(_1, branch) }
          end
          tools = @tool_results_mutex.synchronize { @tool_results.drop(tool_offset) }
          consumed = @ledger ? @ledger.consumed : {}
          [Composite::Effects.new(usage_entries: usage, tool_results: tools, budget_consumed: consumed), nil]
        rescue WorkflowError, ArgumentError => e
          safe = Composite::Effects.new(usage_entries: usage || [], tool_results: [], budget_consumed: consumed || {})
          [safe, e]
        end

        def composite_usage_entry(entry, branch)
          attributes = entry.to_h
          recorded_agent = attributes[:agent_name]
          if recorded_agent && recorded_agent.to_s != branch.agent
            raise WorkflowError, "composite usage entry does not match the executed branch agent"
          end

          attributes.merge(agent_name: branch.agent)
        end
      end
    end
  end
end
