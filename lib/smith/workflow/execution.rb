# frozen_string_literal: true

module Smith
  class Workflow
    module Execution
      private

      def execute_step(transition)
        agent_class = resolve_agent_class(transition)
        output = run_guarded_step(transition, agent_class)
        complete_step(transition, output)
      rescue Smith::Error => e
        handle_step_failure(transition, e)
        { transition: transition.name, from: transition.from, to: transition.to, error: e }
      ensure
        Tool.current_guardrails = nil
      end

      def run_guarded_step(transition, agent_class)
        run_input_guardrails(agent_class)
        apply_tool_guardrails(agent_class)

        output = if transition.parallel?
                   execute_parallel_step(transition)
                 else
                   execute_transition_body(transition)
                 end

        run_output_guardrails(output, agent_class)
        output
      end

      def complete_step(transition, output)
        @state = transition.to
        @next_transition_name = transition.success_transition
        emit_step_completed(transition, output)
        { transition: transition.name, from: transition.from, to: transition.to, output: output }
      end

      def resolve_agent_class(transition)
        return nil unless transition.agent_name

        Agent::Registry.find(transition.agent_name)
      end

      def execute_transition_body(transition)
        return nil unless transition.agent_name

        Agent::Registry.find(transition.agent_name)
        nil
      end

      def execute_parallel_step(transition)
        count = resolve_branch_count(transition)
        branches = Array.new(count) do |i|
          proc { |_signal| { branch: i, agent: transition.agent_name, output: nil } }
        end
        Parallel.execute(branches: branches)
      end

      def resolve_branch_count(transition)
        count = transition.agent_opts[:count]
        count.respond_to?(:call) ? count.call(@context) : (count || 1)
      end

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

      def handle_step_failure(transition, _error)
        failure_name = transition.failure_transition
        return unless failure_name

        fail_transition = self.class.find_transition(failure_name)
        return unless fail_transition

        @state = fail_transition.to
      end

      def emit_step_completed(_transition, _output)
        Smith::Events.emit(
          Smith::Event.new(
            execution_id: SecureRandom.uuid,
            trace_id: SecureRandom.uuid
          )
        )
      end
    end
  end
end
