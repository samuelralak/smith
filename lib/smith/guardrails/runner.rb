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
          raise build_guardrail_error(error_class, e)
        end

        def build_guardrail_error(error_class, error)
          return error_class.new(error.message, retryable: retryable_tool_guardrail?(error.message)) if error_class == ToolGuardrailFailed

          error_class.new(error.message)
        end

        def retryable_tool_guardrail?(message)
          text = message.to_s.downcase
          text.include?("rate limit") || text.include?("malformed args")
        end
      end
    end
  end
end
