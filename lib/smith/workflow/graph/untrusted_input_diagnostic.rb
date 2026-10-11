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

        # The context keys an agent reads as inputs: its declared `inputs`,
        # without the reserved names Smith never reads from the context.
        def self.context_inputs(agent_name)
          agent_class = Agent::Registry.binding_for(agent_name)&.fetch(:agent_class)
          inputs = agent_class.respond_to?(:inputs) ? Array(agent_class.inputs) : []
          inputs - Agent::RESERVED_INPUT_NAMES
        end

        # The untrusted context keys a workflow class declares.
        def self.declared_keys(workflow_class)
          manager = workflow_class.context_manager if workflow_class.respond_to?(:context_manager)
          manager.respond_to?(:untrusted_keys) ? manager.untrusted_keys : []
        end

        def self.suggestion(key)
          "Pass #{Reference.format(key)} through the step's input:, wrapped with Smith::Untrusted.wrap."
        end

        def call
          key = untrusted_input
          return unless key

          Diagnostic.new(
            severity: :error, code: :untrusted_agent_input, transition: binding.fetch(:transition).name,
            target: binding.fetch(:agent), message: message(key), suggestion: self.class.suggestion(key)
          )
        end

        def untrusted_input
          (self.class.context_inputs(binding.fetch(:agent)) & self.class.declared_keys(graph.workflow_class)).first
        end

        def message(key)
          role = binding.fetch(:role)
          "#{role[0].upcase}#{role[1..]} #{Reference.format(binding.fetch(:agent))} on transition " \
            "#{Reference.format(binding.fetch(:transition).name)} declares untrusted context key " \
            "#{Reference.format(key)} as an input."
        end
      end
    end
  end
end
