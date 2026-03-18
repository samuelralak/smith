# frozen_string_literal: true

module Smith
  class Guardrails
    module Runner
      class << self
        def run_inputs(guardrails_class, payload)
          run_layer(guardrails_class, guardrails_class.input, payload, GuardrailFailed)
        end

        def run_outputs(guardrails_class, payload)
          run_layer(guardrails_class, guardrails_class.output, payload, GuardrailFailed)
        end

        def run_tool(guardrails_class, tool_name, payload)
          matching = guardrails_class.tool.select { |d| d[:on]&.include?(tool_name) }
          run_layer(guardrails_class, matching, payload, ToolGuardrailFailed)
        end

        private

        def run_layer(guardrails_class, declarations, payload, error_class)
          instance = guardrails_class.new
          declarations.each { |d| instance.send(d[:name], payload) }
        rescue Smith::Error
          raise
        rescue StandardError => e
          raise error_class, e.message
        end
      end
    end
  end
end
