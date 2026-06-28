# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class TransitionDiagnostics
        attr_reader :graph

        def initialize(graph)
          @graph = graph
        end

        def to_a
          graph.transitions.values.flat_map do |transition|
            [
              transition_target_diagnostic(transition, :success_transition, transition.success_transition),
              transition_target_diagnostic(transition, :failure_transition, transition.failure_transition),
              *router_target_diagnostics(transition),
              *target_state_mismatch_diagnostics(transition)
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

        def target_state_mismatch_diagnostics(transition)
          Targets.for(transition).filter_map do |target_name|
            target = graph.transitions[target_name]
            next unless target
            next if target.from.nil? || target.from == transition.to

            mismatch_diagnostic(transition, target_name, target)
          end
        end

        def mismatch_diagnostic(transition, target_name, target)
          Diagnostic.new(
            severity: :warning,
            code: :target_from_state_mismatch,
            transition: transition.name,
            target: target_name,
            state: transition.to,
            message: "Transition #{ref(transition.name)} can route to #{ref(target_name)}, " \
                     "but #{ref(target_name)} starts from #{ref(target.from)} instead of #{ref(transition.to)}.",
            suggestion: "Align #{ref(target_name)}'s from state with #{ref(transition.to)}, " \
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
