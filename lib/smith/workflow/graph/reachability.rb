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

          root = successors.initial_transition
          return unless root

          walk(root) { yield _1 }
        end

        private

        def successors
          @successors ||= ExecutionSuccessors.new(graph)
        end

        def walk(root)
          seen = {}
          stack = [root]
          until stack.empty?
            transition = stack.pop
            next if seen.key?(transition.name)

            seen[transition.name] = true
            yield transition
            successors.for(transition).reverse_each { stack << _1 }
          end
        end
      end
    end
  end
end
