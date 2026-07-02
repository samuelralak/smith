# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class RuntimeBindingDiagnostics
        extend Dry::Initializer

        param :graph

        def to_a
          agent_bindings.filter_map do |binding|
            RuntimeBindingDiagnosticBuilder.new(graph, binding: binding).to_diagnostic
          end
        end

        def agent_bindings
          @agent_bindings ||= graph.transitions.values.flat_map do |transition|
            bindings_for_transition(transition)
          end
        end

        private

        def bindings_for_transition(transition)
          [
            primary_agent_binding(transition),
            *optimizer_agent_bindings(transition),
            *orchestrator_agent_bindings(transition),
            *fanout_agent_bindings(transition)
          ].compact
        end

        def primary_agent_binding(transition)
          return unless transition.agent_name

          {
            transition: transition,
            role: agent_role_for(transition),
            agent: transition.agent_name,
            requires_model: transition.routed?
          }
        end

        def optimizer_agent_bindings(transition)
          config = transition.optimization_config
          return [] unless config

          [
            {
              transition: transition,
              role: "optimizer generator",
              agent: config.fetch(:generator),
              requires_model: true
            },
            {
              transition: transition,
              role: "optimizer evaluator",
              agent: config.fetch(:evaluator),
              requires_model: true
            }
          ]
        end

        def orchestrator_agent_bindings(transition)
          config = transition.orchestrator_config
          return [] unless config

          [
            {
              transition: transition,
              role: "orchestrator",
              agent: config.fetch(:orchestrator),
              requires_model: true
            },
            {
              transition: transition,
              role: "worker",
              agent: config.fetch(:worker),
              requires_model: true
            }
          ]
        end

        def fanout_agent_bindings(transition)
          branches = transition.fanout_config&.fetch(:branches, nil)
          return [] unless branches

          branches.map do |branch, agent|
            {
              transition: transition,
              role: "fan-out branch #{ref(branch)}",
              agent: agent,
              requires_model: false
            }
          end
        end

        def agent_role_for(transition)
          return "router agent" if transition.routed?
          return "parallel agent" if transition.parallel?

          "agent"
        end

        def ref(value)
          Reference.format(value)
        end
      end
    end
  end
end
