# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class RuntimeReadinessReportBuilder
        extend Dry::Initializer

        param :graph
        option :reports
        option :cycle_transitions

        def call
          topology_report = graph.validate
          bindings = RuntimeBindingDiagnostics.new(graph)
          nested = NestedReadinessDiagnostics.new(graph, reports:, cycle_transitions:)
          diagnostics = [*bindings.to_a, *nested.to_a]
          RuntimeReadinessReport.new(
            workflow_class: workflow_label,
            topology_report: topology_report,
            runtime_diagnostics: diagnostics,
            metrics: metrics(topology_report, diagnostics, bindings, nested)
          )
        end

        private

        def metrics(topology_report, diagnostics, bindings, nested)
          RuntimeReadinessMetrics.new(
            graph,
            topology_report: topology_report,
            runtime_diagnostics: diagnostics,
            agent_bindings: bindings.agent_bindings,
            nested_reports: nested.child_reports
          ).to_h
        end

        def workflow_label
          name = graph.workflow_class.name
          name && !name.empty? ? name : graph.workflow_class.inspect
        end
      end
    end
  end
end
