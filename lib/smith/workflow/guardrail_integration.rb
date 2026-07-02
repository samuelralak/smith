# frozen_string_literal: true

module Smith
  class Workflow
    module GuardrailIntegration
      private

      def apply_tool_guardrails(agent_class)
        sources = tool_guardrail_sources(agent_class)
        Tool.current_guardrails = sources.empty? ? nil : sources
      end

      def run_input_guardrails(agent_class)
        run_workflow_input_guardrails
        run_agent_input_guardrails(agent_class)
      end

      def run_output_guardrails(output, agent_class)
        run_workflow_output_guardrails(output)
        run_agent_output_guardrails(output, agent_class)
      end

      def handle_step_failure(transition, error)
        failure_name = transition.failure_transition
        raise error unless failure_name

        fail_transition = self.class.find_transition(failure_name)
        raise error unless fail_transition
        validate_transition_origin!(fail_transition)

        if actionable_failure_transition?(fail_transition)
          @next_transition_name = failure_name
          return
        end

        @state = fail_transition.to
      end

      def actionable_failure_transition?(transition)
        transition.agent_name ||
          transition.deterministic? ||
          transition.routed? ||
          transition.fanout? ||
          transition.nested? ||
          transition.optimized? ||
          transition.orchestrated? ||
          transition.success_transition
      end

      def run_workflow_input_guardrails
        wf_guardrails = self.class.guardrails
        Guardrails::Runner.run_inputs(wf_guardrails, @context) if wf_guardrails
      end

      def run_agent_input_guardrails(agent_class)
        agent_guardrails = agent_class&.guardrails
        Guardrails::Runner.run_inputs(agent_guardrails, @context) if agent_guardrails
      end

      def run_workflow_output_guardrails(output)
        wf_guardrails = self.class.guardrails
        Guardrails::Runner.run_outputs(wf_guardrails, output) if wf_guardrails
      end

      def run_agent_output_guardrails(output, agent_class)
        agent_guardrails = agent_class&.guardrails
        Guardrails::Runner.run_outputs(agent_guardrails, output) if agent_guardrails
      end

      def tool_guardrail_sources(agent_class)
        [self.class.guardrails, agent_class&.guardrails].compact
      end
    end
  end
end
