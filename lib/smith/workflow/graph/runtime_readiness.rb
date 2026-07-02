# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class RuntimeReadiness
        extend Dry::Initializer

        param :graph
        option :visited, default: proc {}

        def report
          RuntimeReadinessReport.new(
            workflow_class: workflow_label(graph.workflow_class),
            topology_report: topology_report,
            runtime_diagnostics: runtime_diagnostics,
            metrics: runtime_metrics
          )
        end

        private

        def topology_report
          @topology_report ||= graph.validate
        end

        def runtime_diagnostics
          @runtime_diagnostics ||= [
            *binding_diagnostics.to_a,
            *nested_diagnostics.to_a
          ]
        end

        def binding_diagnostics
          @binding_diagnostics ||= RuntimeBindingDiagnostics.new(graph)
        end

        def nested_diagnostics
          @nested_diagnostics ||= NestedReadinessDiagnostics.new(graph, visited: visited)
        end

        def runtime_metrics
          RuntimeReadinessMetrics.new(
            graph,
            topology_report: topology_report,
            runtime_diagnostics: runtime_diagnostics,
            agent_bindings: binding_diagnostics.agent_bindings,
            nested_reports: nested_diagnostics.child_reports
          ).to_h
        end

        def workflow_label(workflow_class)
          name = workflow_class.name
          return name if name && !name.empty?

          workflow_class.inspect
        end
      end
    end
  end
end
