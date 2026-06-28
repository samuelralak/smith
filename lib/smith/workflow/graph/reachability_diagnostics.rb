# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class ReachabilityDiagnostics
        attr_reader :graph, :reachable_transition_names

        def initialize(graph, reachable_transition_names)
          @graph = graph
          @reachable_transition_names = reachable_transition_names
        end

        def to_a
          (graph.transitions.keys - reachable_transition_names).filter_map do |transition_name|
            next if auto_fail_transition?(transition_name)

            diagnostic_for(transition_name)
          end
        end

        private

        def auto_fail_transition?(transition_name)
          transition_name == :fail && graph.transitions[transition_name]&.from.nil?
        end

        def diagnostic_for(transition_name)
          transition = graph.transitions.fetch(transition_name)
          Diagnostic.new(
            severity: :warning,
            code: :unreachable_transition,
            transition: transition_name,
            state: transition.from,
            message: "Transition #{ref(transition_name)} is not reachable from " \
                     "initial_state #{ref(graph.initial_state)}.",
            suggestion: "Connect transition #{ref(transition_name)} from a reachable state or remove it."
          )
        end

        def ref(value)
          Reference.format(value)
        end
      end
    end
  end
end
