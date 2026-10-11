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
        # The graphs the readiness walk built, by workflow class.
        option :graphs, default: proc { {}.compare_by_identity }

        def to_a
          cycle_diagnostics + waiting_child_diagnostics + inherited_untrusted_diagnostics +
            report_entries.flat_map { |entry| diagnostics_for(entry) }
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
            workflow_class = transition.target_workflow_class
            cycle_diagnostic(transition, workflow_class)
          end
        end

        def report_entries
          @report_entries ||= nested_workflow_transitions.filter_map do |transition|
            next if cycle_transitions.key?(transition)

            workflow_class = transition.target_workflow_class
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
          @nested_workflow_transitions ||= graph.reachable_transitions.select do |transition|
            transition.nested? || transition.child_runs?
          end
        end

        # An in-process child cannot wait: a nested workflow, or a child run
        # the launcher runs in process (`inline?`), that reaches an await, a
        # delay or a durable retry fails its parent's step. A nested
        # workflow cannot launch runs either, unless the launcher runs them
        # in process; a child run of a queueing launcher is a run of its own
        # and may wait.
        def waiting_child_diagnostics
          launcher = Smith.config.run_launcher
          inline = launcher.respond_to?(:inline?) && launcher.inline? == true
          report_entries.filter_map do |entry|
            transition = entry.fetch(:transition)
            next unless (transition.nested? || (inline && transition.child_runs?)) && waiting_child?(entry, inline)

            WaitingChildDiagnostic.build(transition, workflow_label(entry.fetch(:workflow_class)))
          end
        end

        def waiting_child?(entry, inline)
          kinds = inline ? %i[await delay] : %i[await delay map call spawn]
          entry.fetch(:report).topology_report.transitions.any? { waits?(_1, kinds) }
        end

        def waits?(snapshot, kinds) = kinds.include?(snapshot.kind) || snapshot.retry_policy&.dig(:durable) == true

        def inherited_untrusted_diagnostics
          entries = report_entries.map do |entry|
            entry.merge(label: workflow_label(entry.fetch(:workflow_class)))
          end
          InheritedUntrustedDiagnostics.new(graph, entries:, graphs:).to_a
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
