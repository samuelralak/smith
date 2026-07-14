# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      EMPTY_TRANSITIONS = [].freeze

      attr_reader :workflow_class, :initial_state, :states, :transitions

      def initialize(workflow_class:, initial_state:, states:, transitions:)
        @identifier_projection = IdentifierProjection.new
        @workflow_class = workflow_class
        @initial_state = project_identifier(initial_state)
        @states = own_states(states)
        @state_index = index_states
        @transitions = own_transitions(transitions)
        @transitions_by_state = build_transitions_by_state
      end

      def validate
        Validator.new(self).report
      end

      def runtime_readiness(visited: nil)
        RuntimeReadiness.new(self, visited: visited).report
      end

      def transition_snapshots
        transitions.values.map do |transition|
          TransitionSnapshot.from_transition(transition, workflow_class: workflow_class)
        end
      end

      def transitions_from(state)
        @transitions_by_state.fetch(state, EMPTY_TRANSITIONS)
      end

      def state?(state)
        @state_index.key?(state)
      end

      private

      def project_identifier(identifier)
        @identifier_projection.call(identifier)
      end

      def own_states(states)
        Array(states).map { project_identifier(_1) }.uniq.freeze
      end

      def index_states
        states.to_h { [_1, true] }.freeze
      end

      def own_transitions(transitions)
        transitions.each_value.with_index.with_object({}) do |(transition, definition_index), snapshot|
          contract = TransitionContract.from_transition(
            transition,
            identifiers: @identifier_projection,
            definition_index:
          )
          snapshot[contract.name] = contract
        end.freeze
      end

      def build_transitions_by_state
        index = transitions.values.each_with_object({}) do |transition, result|
          (result[transition.from] ||= []) << transition
        end
        index.each_value(&:freeze)
        index.freeze
      end
    end
  end
end

require_relative "graph/reference"
require_relative "graph/identifier_projection"
require_relative "graph/transition_contract"
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
require_relative "graph/optimization_contract"
require_relative "graph/orchestration_contract"
require_relative "graph/transition_snapshot"
require_relative "graph/transition_diagnostics"
require_relative "graph/validator"
require_relative "graph/runtime_readiness"
