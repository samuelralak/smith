# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class Validator
        attr_reader :graph

        def initialize(graph)
          @graph = graph
        end

        def report
          diagnostics = all_diagnostics

          Report.new(
            status: status_for(diagnostics),
            workflow_class: graph.workflow_class.name,
            initial_state: graph.initial_state,
            states: graph.states,
            transitions: graph.transition_snapshots,
            diagnostics: diagnostics,
            metrics: Metrics.new(graph, reachable_transition_names).to_h
          )
        end

        private

        def all_diagnostics
          [
            *StateDiagnostics.new(graph).to_a,
            *TransitionDiagnostics.new(graph).to_a,
            *ReachabilityDiagnostics.new(graph, reachable_transition_names).to_a
          ]
        end

        def reachable_transition_names
          @reachable_transition_names ||= Reachability.new(graph).transition_names
        end

        def status_for(diagnostics)
          return :invalid if diagnostics.any? { |diagnostic| diagnostic.severity == :error }
          return :warning if diagnostics.any?

          :valid
        end
      end
    end
  end
end
