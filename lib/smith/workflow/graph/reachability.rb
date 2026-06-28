# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class Reachability
        attr_reader :graph

        def initialize(graph)
          @graph = graph
        end

        def transition_names
          return [] unless graph.initial_state

          reset_walk
          drain_queue
          @seen_transitions.keys
        end

        private

        def reset_walk
          @seen_states = { graph.initial_state => true }
          @seen_transitions = {}
          @queue = [graph.initial_state]
        end

        def drain_queue
          transitions_from(@queue.shift).each { |transition| visit_transition(transition) } until @queue.empty?
        end

        def visit_transition(transition)
          return if @seen_transitions.key?(transition.name)

          @seen_transitions[transition.name] = true
          enqueue_state(transition.to)
          Targets.for(transition).each { |target_name| visit_named_transition(target_name) }
        end

        def visit_named_transition(target_name)
          target = graph.transitions[target_name]
          visit_transition(target) if target
        end

        def enqueue_state(state)
          return if state.nil? || @seen_states.key?(state)

          @seen_states[state] = true
          @queue << state
        end

        def transitions_from(state)
          graph.transitions.values.select { |transition| transition.from == state }
        end
      end
    end
  end
end
