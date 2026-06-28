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
  end
end
