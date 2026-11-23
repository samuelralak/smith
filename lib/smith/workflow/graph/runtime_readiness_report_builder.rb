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
        option :graphs, default: proc { {}.compare_by_identity }

        def call
          topology_report = graph.validate
          bindings = RuntimeBindingDiagnostics.new(graph)
          nested = NestedReadinessDiagnostics.new(graph, reports:, cycle_transitions:, graphs:)
          diagnostics = runtime_diagnostics(bindings, nested)
          RuntimeReadinessReport.new(
            workflow_class: workflow_label,
            topology_report: topology_report,
            runtime_diagnostics: diagnostics,
            metrics: metrics(topology_report, diagnostics, bindings, nested)
          )
        end

        private

        def runtime_diagnostics(bindings, nested)
          checks = [RunLauncherDiagnostic, DurableRetryDiagnostic, StreamDiagnostic, BatchDiagnostic,
                    BudgetLedgerDiagnostic]
          [*bindings.to_a, *checks.flat_map { _1.new(graph).to_a }, *run_credentials_diagnostics, *nested.to_a]
        end

        # Only for a class that declares provider_credentials, or under the
        # fail-closed mode, and loaded only then: any other class reads as
        # before.
        def run_credentials_diagnostics
          klass = graph.workflow_class
          declared = klass.respond_to?(:provider_credentials) && !klass.provider_credentials.nil?
          return [] unless declared || Smith.config.require_run_credentials

          require_relative "../../run_credentials_readiness"
          RunCredentialsReadiness.new(graph).to_a
        end

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
