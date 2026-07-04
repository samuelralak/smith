# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      attr_reader :workflow_class, :initial_state, :states, :transitions

      def initialize(workflow_class:, initial_state:, states:, transitions:)
        @workflow_class = workflow_class
        @initial_state = initial_state
        @states = Array(states).uniq.freeze
        @transitions = transitions.dup.freeze
      end

      def validate
        Validator.new(self).report
      end

      def runtime_readiness(visited: nil)
        RuntimeReadiness.new(self, visited: visited).report
      end

      def transition_snapshots
        transitions.values.map { |transition| TransitionSnapshot.from_transition(transition, workflow_class: workflow_class) }
      end
    end
  end
end

require_relative "graph/reference"
require_relative "graph/diagnostic"
require_relative "graph/state_diagnostics"
require_relative "graph/reachability"
require_relative "graph/reachability_diagnostics"
require_relative "graph/metrics"
require_relative "graph/nested_readiness_diagnostics"
require_relative "graph/report"
require_relative "graph/runtime_binding_diagnostic_builder"
require_relative "graph/runtime_binding_diagnostics"
require_relative "graph/runtime_readiness_report"
require_relative "graph/runtime_readiness_metrics"
require_relative "graph/targets"
require_relative "graph/fanout_contract"
require_relative "graph/transition_snapshot"
require_relative "graph/transition_diagnostics"
require_relative "graph/validator"
require_relative "graph/runtime_readiness"
