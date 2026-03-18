# frozen_string_literal: true

module Smith
  class Workflow
    module GuardrailIntegration
      private

      def apply_tool_guardrails(agent_class)
        sources = [self.class.guardrails, agent_class&.guardrails].compact
        Tool.current_guardrails = sources.empty? ? nil : sources
      end

      def run_input_guardrails(agent_class)
        wf_guardrails = self.class.guardrails
        Guardrails::Runner.run_inputs(wf_guardrails, @context) if wf_guardrails

        agent_guardrails = agent_class&.guardrails
        Guardrails::Runner.run_inputs(agent_guardrails, @context) if agent_guardrails
      end

      def run_output_guardrails(output, agent_class)
        wf_guardrails = self.class.guardrails
        Guardrails::Runner.run_outputs(wf_guardrails, output) if wf_guardrails

        agent_guardrails = agent_class&.guardrails
        Guardrails::Runner.run_outputs(agent_guardrails, output) if agent_guardrails
      end
    end
  end
end
