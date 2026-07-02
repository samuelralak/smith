# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class RuntimeReadinessReport
        extend Dry::Initializer

        option :workflow_class
        option :topology_report
        option :runtime_diagnostics
        option :metrics

        def ready?
          errors.empty?
        end
        alias valid? ready?

        def status
          return :not_ready if errors.any?
          return :warning if warnings.any?

          :ready
        end

        def topology_status
          topology_report.status
        end

        def diagnostics
          topology_report.diagnostics + runtime_diagnostics
        end

        def errors
          diagnostics.select { |diagnostic| diagnostic.severity == :error }
        end

        def warnings
          diagnostics.select { |diagnostic| diagnostic.severity == :warning }
        end

        def suggestions
          diagnostics.map(&:suggestion).compact.uniq
        end

        def to_h
          {
            status: status,
            workflow_class: workflow_class,
            topology_status: topology_status,
            ready: ready?,
            diagnostics: diagnostics.map(&:to_h),
            runtime_diagnostics: runtime_diagnostics.map(&:to_h),
            topology_diagnostics: topology_report.diagnostics.map(&:to_h),
            suggestions: suggestions,
            metrics: metrics,
            graph: topology_report.to_h
          }
        end
      end
    end
  end
end
