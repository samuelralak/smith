# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class RuntimeReadinessMetrics
        extend Dry::Initializer

        param :graph
        option :topology_report
        option :runtime_diagnostics
        option :agent_bindings
        option :nested_reports, default: proc { [] }

        def to_h
          core_metrics.merge(
            binding_metrics,
            nested_workflow_metrics,
            fanout_metrics
          )
        end

        private

        def core_metrics
          {
            topology_status: topology_report.status,
            unresolved_agent_bindings_count: diagnostic_count(:unresolved_agent_binding),
            invalid_agent_bindings_count: diagnostic_count(:invalid_agent_binding),
            uninspectable_agent_bindings_count: diagnostic_count(:uninspectable_agent_binding),
            modelless_agent_bindings_count: diagnostic_count(:agent_without_model),
            required_model_missing_count: diagnostic_count(:agent_without_required_model)
          }
        end

        def binding_metrics
          {
            direct_agent_bindings_count: agent_bindings.length,
            agent_bindings_count: agent_bindings.length + nested_metric_sum(:agent_bindings_count)
          }
        end

        def nested_workflow_metrics
          {
            direct_nested_workflow_count: direct_nested_workflow_count,
            nested_workflow_count: direct_nested_workflow_count + nested_metric_sum(:nested_workflow_count)
          }
        end

        def fanout_metrics
          {
            direct_fanout_groups_count: fanout_transitions.length,
            fanout_groups_count: fanout_transitions.length + nested_metric_sum(:fanout_groups_count),
            direct_fanout_branches_count: fanout_branch_count,
            fanout_branches_count: fanout_branch_count + nested_metric_sum(:fanout_branches_count)
          }
        end

        def nested_metric_sum(key)
          nested_reports.sum { |report| report.metrics.fetch(key, 0) }
        end

        def diagnostic_count(code)
          runtime_diagnostics.count do |diagnostic|
            diagnostic.code.to_s.end_with?(code.to_s)
          end
        end

        def fanout_branch_count
          fanout_transitions.sum do |transition|
            transition.fanout_config.fetch(:branches).length
          end
        end

        def fanout_transitions
          @fanout_transitions ||= graph.reachable_transitions.select(&:fanout?)
        end

        def direct_nested_workflow_count
          graph.reachable_transitions.count(&:nested?)
        end
      end
    end
  end
end
