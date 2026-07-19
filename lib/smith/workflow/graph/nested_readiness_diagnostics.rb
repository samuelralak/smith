# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class NestedReadinessDiagnostics
        extend Dry::Initializer

        param :graph
        option :reports
        option :cycle_transitions, default: proc { {}.compare_by_identity }

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
          cycle_transitions.keys.map do |transition|
            workflow_class = transition.workflow_class
            cycle_diagnostic(transition, workflow_class)
          end
        end

        def report_entries
          @report_entries ||= nested_workflow_transitions.filter_map do |transition|
            next if cycle_transitions.key?(transition)

            workflow_class = transition.workflow_class
            report = reports[workflow_class]
            next unless report

            {
              transition: transition,
              workflow_class: workflow_class,
              report: report
            }.freeze
          end.freeze
        end

        def nested_workflow_transitions
          @nested_workflow_transitions ||= graph.reachable_transitions.select(&:nested?)
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
          code = diagnostic.code.to_s.start_with?("nested_") ? diagnostic.code : :"nested_#{diagnostic.code}"

          diagnostic.nested(
            label: label,
            code: code,
            transition: transition.name,
            target: label
          )
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
