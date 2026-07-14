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
          each_transition.map(&:name)
        end

        def each_transition
          return enum_for(__method__) unless block_given?
          return unless graph.initial_state

          reset_walk
          drain_queue { yield _1 }
        end

        private

        def reset_walk
          @seen_states = { graph.initial_state => true }
          @seen_transitions = {}
          @queue = [graph.initial_state]
          @queue_index = 0
        end

        def drain_queue(&block)
          while @queue_index < @queue.length
            state = @queue.fetch(@queue_index)
            @queue_index += 1
            transitions_from(state).each { |transition| visit_transition(transition, &block) }
          end
        end

        def visit_transition(root)
          stack = [root]
          until stack.empty?
            transition = stack.pop
            next if @seen_transitions.key?(transition.name)

            @seen_transitions[transition.name] = true
            yield transition
            enqueue_state(transition.to)

            Targets.for(transition).reverse_each do |target_name|
              target = graph.transitions[target_name]
              stack << target if target
            end
          end
        end

        def enqueue_state(state)
          return if state.nil? || @seen_states.key?(state)

          @seen_states[state] = true
          @queue << state
        end

        def transitions_from(state)
          graph.transitions_from(state)
        end
      end
    end
  end
end
