# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class TransitionDiagnostics
        TARGET_ATTRIBUTES = %i[success_transition failure_transition timeout_transition].freeze
        DECLARATION_CHECKS = [
          BranchLimitDiagnostic, RetryPolicyDiagnostic, AwaitTimeoutRouteDiagnostic, IsolatedInputDiagnostic
        ].freeze
        attr_reader :graph

        def initialize(graph)
          @graph = graph
        end

        def to_a
          graph.transitions.values.flat_map do |transition|
            [
              *TARGET_ATTRIBUTES.map { transition_target_diagnostic(transition, _1, transition.public_send(_1)) },
              *router_target_diagnostics(transition),
              *deterministic_route_diagnostics(transition),
              *target_state_mismatch_diagnostics(transition),
              *declaration_diagnostics(transition)
            ].compact
          end
        end

        private

        def transition_target_diagnostic(transition, code, target)
          return if target.nil?
          return if graph.transitions.key?(target)

          Diagnostic.new(
            severity: :error,
            code: :"unresolved_#{code}",
            transition: transition.name,
            target: target,
            message: "Transition #{ref(transition.name)} references missing transition #{ref(target)}.",
            suggestion: "Declare transition #{ref(target)} or update transition #{ref(transition.name)}."
          )
        end

        def router_target_diagnostics(transition)
          return [] unless transition.router_config

          Targets.router_for(transition).filter_map do |target|
            transition_target_diagnostic(transition, :router_target, target)
          end
        end

        def deterministic_route_diagnostics(transition)
          Array(transition.deterministic_routes).filter_map do |target|
            transition_target_diagnostic(transition, :deterministic_route, target)
          end
        end

        def target_state_mismatch_diagnostics(transition)
          success = successful_target_names(transition).filter_map do |target_name|
            target_state_mismatch_diagnostic(transition, target_name, expected_state: transition.to)
          end
          failure = target_state_mismatch_diagnostic(
            transition,
            transition.failure_transition,
            expected_state: transition.from
          )
          timeout = target_state_mismatch_diagnostic(transition, transition.timeout_transition,
                                                     expected_state: transition.from)

          [*success, failure, timeout].compact
        end

        def declaration_diagnostics(transition)
          DECLARATION_CHECKS.map { _1.new(transition:, workflow_class: graph.workflow_class).call }
        end

        def successful_target_names(transition)
          return Targets.router_for(transition) if transition.routed?

          [transition.success_transition, *Array(transition.deterministic_routes)].compact.uniq
        end

        def target_state_mismatch_diagnostic(transition, target_name, expected_state:)
          return if target_name.nil?

          target = graph.transitions[target_name]
          return unless target
          return if target.from.nil? || target.from == expected_state

          mismatch_diagnostic(transition, target_name, target, expected_state:)
        end

        def mismatch_diagnostic(transition, target_name, target, expected_state:)
          Diagnostic.new(
            severity: :error,
            code: :target_from_state_mismatch,
            transition: transition.name,
            target: target_name,
            state: expected_state,
            message: "Transition #{ref(transition.name)} can route to #{ref(target_name)}, " \
                     "but #{ref(target_name)} starts from #{ref(target.from)} instead of #{ref(expected_state)}.",
            suggestion: "Align #{ref(target_name)}'s from state with #{ref(expected_state)}, " \
                        "or remove the named route."
          )
        end

        def ref(value)
          Reference.format(value)
        end
      end
    end
  end
end
