# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # An agent declared for Anthropic whose output schema Anthropic's
      # structured outputs cannot take (an object that allows other
      # properties or declares none) fails before its call.
      class OutputSchemaDiagnostic
        extend Dry::Initializer

        option :binding

        def call
          agent_class = Agent::Registry.binding_for(binding.fetch(:agent))&.fetch(:agent_class)
          payload = anthropic_schema(agent_class)
          return unless payload

          Providers::SchemaConstraints.for_provider(payload, "anthropic")
          nil
        rescue Smith::WorkflowError => e
          diagnostic(e)
        end

        private

        def anthropic_schema(agent_class)
          return unless agent_class.respond_to?(:chat_kwargs) && agent_class.chat_kwargs[:provider].to_s == "anthropic"

          schema = agent_class.output_schema || (agent_class.schema if agent_class.respond_to?(:schema))
          Providers::SchemaConstraints.json_schema(schema) if schema && !schema.is_a?(Proc)
        end

        def diagnostic(error)
          agent = binding.fetch(:agent)
          Diagnostic.new(
            severity: :error, code: :output_schema_unsupported, transition: binding.fetch(:transition).name,
            target: agent,
            message: "Agent #{Reference.format(agent)} declares an output schema Anthropic cannot take: " \
                     "#{error.message}.",
            suggestion: "Give every object in the schema its properties and additionalProperties: false."
          )
        end
      end
    end
  end
end
