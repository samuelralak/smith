# frozen_string_literal: true

require_relative "../transition_actionability"

module Smith
  class Workflow
    class Graph
      class ExecutionSuccessors
        attr_reader :graph

        def initialize(graph)
          @graph = graph
        end

        def initial_transition
          graph.first_transition_from(graph.initial_state)
        end

        def for(transition)
          successful_successors(transition) + failure_successors(transition)
        end

        def failure_control_marker(transition)
          target = executable_target(transition.failure_transition, expected_state: transition.from)
          target if target && !TransitionActionability.call(target)
        end

        private

        def successful_successors(transition)
          successful_target_names(transition).filter_map do |name|
            executable_target(name, expected_state: transition.to)
          end
        end

        def failure_successors(transition)
          target = executable_target(transition.failure_transition, expected_state: transition.from)
          return [] unless target
          return [target] if TransitionActionability.call(target)

          successor = graph.first_transition_from(target.to)
          successor ? [successor] : []
        end

        def successful_target_names(transition)
          return Targets.router_for(transition) if transition.routed?

          names = Array(transition.deterministic_routes).dup
          name = transition.success_transition || graph.first_transition_from(transition.to)&.name
          names << name if name
          names.uniq
        end

        def executable_target(name, expected_state:)
          return if name.nil?

          target = graph.transitions[name]
          return unless target

          target if target.from.nil? || target.from == expected_state
        end
      end
    end
  end
end
