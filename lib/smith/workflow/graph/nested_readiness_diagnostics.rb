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

        # An in-process child that reaches an await, a delay or a durable
        # retry fails its parent's step at runtime; a child run of its own
        # may wait.
        # An in-process child has no persisted key, so it cannot wait, nor
        # launch runs of its own unless the launcher runs them in process.
        def waiting_child_diagnostics
          kinds = waiting_kinds
          in_process_entries.filter_map do |entry|
            next unless entry.fetch(:report).topology_report.transitions.any? { waits?(_1, kinds) }

            waiting_child_diagnostic(entry.fetch(:transition), workflow_label(entry.fetch(:workflow_class)))
          end
        end

        def waits?(snapshot, kinds) = kinds.include?(snapshot.kind) || snapshot.retry_policy&.dig(:durable) == true

        def waiting_kinds
          launcher = Smith.config.run_launcher
          inline = launcher.respond_to?(:inline?) && launcher.inline? == true
          inline ? %i[await delay] : %i[await delay map call spawn]
        end

        def waiting_child_diagnostic(transition, label)
          Diagnostic.new(
            severity: :error, code: :nested_workflow_waits, transition: transition.name, target: label,
            message: "Transition #{ref(transition.name)} nests #{label}, which reaches a step that waits " \
                     "or launches runs of its own.",
            suggestion: "An in-process nested workflow cannot wait or launch; move the step into the parent workflow."
          )
        end

        def inherited_untrusted_diagnostics
          entries = report_entries.map do |entry|
            entry.merge(label: workflow_label(entry.fetch(:workflow_class)))
          end
          InheritedUntrustedDiagnostics.new(graph, entries:, graphs:).to_a
        end

        def in_process_entries = report_entries.select { _1.fetch(:transition).nested? }

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
