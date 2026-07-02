# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class NestedReadinessDiagnostics
        extend Dry::Initializer

        param :graph
        option :visited, default: proc {}

        def to_a
          cycle_diagnostics + report_entries.flat_map { |entry| diagnostics_for(entry) }
        end

        def child_reports
          report_entries.map { |entry| entry.fetch(:report) }
        end

        private

        def diagnostics_for(entry)
          entry.fetch(:report).diagnostics.map do |diagnostic|
            nested_diagnostic(entry.fetch(:transition), entry.fetch(:workflow_class), diagnostic)
          end
        end

        def cycle_diagnostics
          nested_workflow_transitions.filter_map do |transition|
            workflow_class = transition.workflow_class
            cycle_diagnostic(transition, workflow_class) if visited_workflows.include?(workflow_class)
          end
        end

        def report_entries
          @report_entries ||= nested_workflow_transitions.filter_map do |transition|
            workflow_class = transition.workflow_class
            next if visited_workflows.include?(workflow_class)

            {
              transition: transition,
              workflow_class: workflow_class,
              report: workflow_class.graph.runtime_readiness(visited: visited_workflows)
            }.freeze
          end.freeze
        end

        def nested_workflow_transitions
          @nested_workflow_transitions ||= graph.transitions.values.select(&:nested?)
        end

        def cycle_diagnostic(transition, workflow_class)
          label = workflow_label(workflow_class)

          Diagnostic.new(
            severity: :error,
            code: :nested_workflow_cycle,
            transition: transition.name,
            target: label,
            message: "Transition #{ref(transition.name)} nests #{label}, " \
                     "which is already in the readiness inspection stack.",
            suggestion: "Break the nested workflow cycle before runtime execution."
          )
        end

        def nested_diagnostic(transition, workflow_class, diagnostic)
          label = workflow_label(workflow_class)

          Diagnostic.new(
            severity: diagnostic.severity,
            code: :"nested_#{diagnostic.code}",
            transition: transition.name,
            target: label,
            message: "Nested workflow #{label}: #{diagnostic.message}",
            suggestion: diagnostic.suggestion
          )
        end

        def visited_workflows
          @visited_workflows ||= Set.new(Array(visited)).add(graph.workflow_class)
        end

        def ref(value)
          Reference.format(value)
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
