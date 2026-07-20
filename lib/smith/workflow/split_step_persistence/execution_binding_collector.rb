# frozen_string_literal: true

require_relative "../../agent"
require_relative "../../agent/registry"

module Smith
  class Workflow
    module SplitStepPersistence
      class ExecutionBindingCollector
        MAX_BINDINGS = 10_000

        def initialize
          @requests = {}
          @bindings = {}
        end

        def capture(transition, workflow_class:)
          capture_binding(transition.agent_name, workflow_class:, transition:, role: :agent)
          capture_fanout(transition, workflow_class:)
          capture_optimization(transition, workflow_class:)
          capture_orchestration(transition, workflow_class:)
        end

        def fetch!(name, workflow_class:, transition_name:, role:)
          @bindings.fetch(name.to_s) do
            raise WorkflowError,
                  "execution authorization does not contain #{role} :#{name} " \
                  "for workflow #{workflow_class}, transition :#{transition_name}"
          end
        end

        def capture_agent(name, workflow_class:, transition:, role:)
          capture_binding(name, workflow_class:, transition:, role:)
          self
        end

        def resolve!
          @bindings = Agent::Registry.capture_bindings!(@requests.values)

          @requests.freeze
          self
        end

        def each(&)
          @bindings.each(&)
        end

        def freeze
          @requests.freeze
          @bindings.freeze
          super
        end

        private

        def capture_fanout(transition, workflow_class:)
          transition.fanout_config&.fetch(:branches, nil)&.each_value do |agent|
            capture_binding(agent, workflow_class:, transition:, role: :fanout_agent)
          end
        end

        def capture_optimization(transition, workflow_class:)
          return unless (config = transition.optimization_config)

          capture_binding(config.fetch(:generator), workflow_class:, transition:, role: :generator)
          capture_binding(config.fetch(:evaluator), workflow_class:, transition:, role: :evaluator)
        end

        def capture_orchestration(transition, workflow_class:)
          return unless (config = transition.orchestrator_config)

          capture_binding(config.fetch(:orchestrator), workflow_class:, transition:, role: :orchestrator)
          capture_binding(config.fetch(:worker), workflow_class:, transition:, role: :worker)
        end

        def capture_binding(name, workflow_class:, transition:, role:)
          return unless name

          key = name.to_s
          return if @requests.key?(key)
          if @requests.length >= MAX_BINDINGS
            raise WorkflowError, "execution authorization exceeds maximum agent bindings #{MAX_BINDINGS}"
          end

          @requests[key] = {
            name:,
            workflow_class:,
            transition_name: transition.name,
            role:
          }.freeze
        end
      end
    end
  end
end
