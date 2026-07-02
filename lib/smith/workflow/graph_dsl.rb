# frozen_string_literal: true

module Smith
  class Workflow
    def self.graph
      Graph.new(
        workflow_class: self,
        initial_state: initial_state,
        states: @states || [],
        transitions: @transitions || {}
      )
    end

    def self.validate_graph
      graph.validate
    end

    def self.runtime_readiness
      graph.runtime_readiness
    end
  end
end
