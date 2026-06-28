# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class Metrics
        attr_reader :graph, :reachable_transition_names

        def initialize(graph, reachable_transition_names)
          @graph = graph
          @reachable_transition_names = reachable_transition_names
        end

        def to_h
          {
            states_count: graph.states.length,
            transitions_count: graph.transitions.length,
            reachable_transitions_count: reachable_transition_names.length,
            terminal_states: terminal_states
          }
        end

        private

        def terminal_states
          graph.states.select do |state|
            graph.transitions.values.none? { |transition| transition.from == state }
          end
        end
      end
    end
  end
end
