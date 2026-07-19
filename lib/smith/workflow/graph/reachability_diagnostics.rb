# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class ReachabilityDiagnostics
        attr_reader :graph, :reachable_transition_names

        def initialize(graph, reachable_transition_names)
          @graph = graph
          @reachable_transition_names = reachable_transition_names
          @reachable_transition_index = reachable_transition_names.to_h { [_1, true] }.freeze
          @control_marker_index = control_marker_index
        end

        def to_a
          (graph.transitions.keys - reachable_transition_names).filter_map do |transition_name|
            next if auto_fail_transition?(transition_name) || control_marker?(transition_name)

            diagnostic_for(transition_name)
          end
        end

        private

        def auto_fail_transition?(transition_name)
          transition_name == :fail && graph.transitions[transition_name]&.from.nil?
        end

        def control_marker?(transition_name)
          @control_marker_index.key?(transition_name)
        end

        def control_marker_index
          successors = ExecutionSuccessors.new(graph)
          graph.transitions.each_value.with_object({}) do |transition, index|
            next unless @reachable_transition_index.key?(transition.name)

            marker = successors.failure_control_marker(transition)
            index[marker.name] = true if marker
          end.freeze
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
