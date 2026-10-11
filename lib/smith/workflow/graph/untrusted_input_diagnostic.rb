# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # An agent that names a context key the workflow's context marks
      # untrusted among its `inputs` is refused at invocation.
      class UntrustedInputDiagnostic
        extend Dry::Initializer

        param :graph
        option :binding

        def call
          key = untrusted_input
          return unless key

          Diagnostic.new(
            severity: :error, code: :untrusted_agent_input, transition: binding.fetch(:transition).name,
            target: binding.fetch(:agent), message: message(key),
            suggestion: "Pass #{Reference.format(key)} through the step's input:, wrapped with Smith::Untrusted.wrap."
          )
        end

        def message(key)
          "#{binding.fetch(:role).capitalize} #{Reference.format(binding.fetch(:agent))} on transition " \
            "#{Reference.format(binding.fetch(:transition).name)} declares untrusted context key " \
            "#{Reference.format(key)} as an input."
        end

        private

        def untrusted_input
          keys = untrusted_keys
          (agent_inputs & keys).first if keys.any?
        end

        def untrusted_keys
          workflow = graph.workflow_class
          manager = workflow.context_manager if workflow.respond_to?(:context_manager)
          manager.respond_to?(:untrusted_keys) ? manager.untrusted_keys : []
        end

        def agent_inputs
          agent_class = Agent::Registry.binding_for(binding.fetch(:agent))&.fetch(:agent_class)
          agent_class.respond_to?(:inputs) ? Array(agent_class.inputs) : []
        end
      end
    end
  end
end
