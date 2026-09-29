# frozen_string_literal: true

require_relative "transition_actionability"

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
        step = { transition: transition.name, from: transition.from, to: transition.to, error: error }
        fold_pending_evaluations(step)
        @pending_evaluations = nil
        # Staged, not emitted: this rescue runs under the step snapshot's
        # interrupt mask, and host StepFailed handlers must not execute
        # unkillable. with_step_context flushes after the mask closes.
        # Staged before the split-step capture so a capture invariant
        # failure still flushes an emission for the original error.
        @pending_step_failure = step
        SplitStepPersistence
          .instance_method(:capture_split_step_execution_result!)
          .bind_call(self, step)
        failure_name = transition.failure_transition
        raise error unless failure_name

        fail_transition = self.class.find_transition(failure_name)
        raise error unless fail_transition

        validate_transition_origin!(fail_transition)

        if actionable_failure_transition?(fail_transition)
          @next_transition_name = failure_name
          return step
        end

        @state = fail_transition.to
        step
      end

      def handle_unresolved_transition_failure(error)
        fail_transition = self.class.find_transition(:fail)
        raise error unless fail_transition

        @outcome = nil
        step = { transition: error.requested_name, from: @state, to: fail_transition.to, error: error }

        # A step body that raised UnresolvedTransitionError was already
        # captured, staged, and emitted under its real transition identity
        # by the step-failure path before advance!'s rescue reached here.
        # Capturing or emitting again would record the same failure twice,
        # the second time under the requested name, a transition that never
        # executed. Routing to :fail still happens either way.
        if error.equal?(@emitted_step_failure_error)
          @state = fail_transition.to
          return step
        end

        SplitStepPersistence
          .instance_method(:capture_split_step_execution_result!)
          .bind_call(self, step)
        # Unlike the step-body path, this handler runs outside any step
        # context (advance! rescues UnresolvedTransitionError after the step
        # unwound), so the run identity must be seeded here or the emitted
        # facts get fallback random ids.
        Attribution.with(execution_key: @persistence_key, workflow: self.class.name || "anonymous") do
          emit_step_failed(step)
        end
        @state = fail_transition.to
        step
      end

      def actionable_failure_transition?(transition)
        TransitionActionability.call(transition)
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
