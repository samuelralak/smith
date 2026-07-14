# frozen_string_literal: true

require "dry-initializer"

require_relative "runtime_readiness_traversal"

module Smith
  class Workflow
    class Graph
      class RuntimeReadiness
        extend Dry::Initializer

        param :graph
        option :visited, default: proc {}

        def report
          RuntimeReadinessTraversal.new(graph, visited:).report
        end
      end
    end
  end
end
