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
          Transition.agent_references(transition).each do |role, name|
            capture_binding(name, workflow_class:, transition:, role:)
          end
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
