# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class StateDiagnostics
        attr_reader :graph

        def initialize(graph)
          @graph = graph
        end

        def to_a
          [
            *initial_state_diagnostics,
            *state_reference_diagnostics
          ]
        end

        private

        def initial_state_diagnostics
          return [] if graph.initial_state && graph.states.include?(graph.initial_state)

          [
            Diagnostic.new(
              severity: :error,
              code: :missing_initial_state,
              state: graph.initial_state,
              message: "Workflow initial_state is not declared as a state.",
              suggestion: "Declare an initial_state and ensure it is included in the workflow states."
            )
          ]
        end

        def state_reference_diagnostics
          graph.transitions.values.flat_map do |transition|
            [
              undefined_state_diagnostic(transition, :from, transition.from),
              undefined_state_diagnostic(transition, :to, transition.to)
            ].compact
          end
        end

        def undefined_state_diagnostic(transition, edge, state)
          return if edge == :from && state.nil?
          return if graph.states.include?(state)

          Diagnostic.new(
            severity: :error,
            code: :"undefined_#{edge}_state",
            state: state,
            transition: transition.name,
            message: "Transition #{ref(transition.name)} references undefined #{edge} state #{ref(state)}.",
            suggestion: "Declare state #{ref(state)} or update transition #{ref(transition.name)}."
          )
        end

        def ref(value)
          Reference.format(value)
        end
      end
    end
  end
end
