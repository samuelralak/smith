# frozen_string_literal: true

module Smith
  class Workflow
    module Execution
      private

      def execute_step(transition)
        agent_class = resolve_agent_class(transition)
        output = run_guarded_step(transition, agent_class)
        complete_step(transition, output)
      rescue StandardError => e
        handle_step_failure(transition, e)
        { transition: transition.name, from: transition.from, to: transition.to, error: e }
      ensure
        Tool.current_guardrails = nil
      end

      def run_guarded_step(transition, agent_class)
        run_input_guardrails(agent_class)
        apply_tool_guardrails(agent_class)
        session = build_session
        prepared_input = session&.prepare!

        output = if transition.parallel?
                   execute_parallel_step(transition)
                 else
                   execute_transition_body(transition, prepared_input: prepared_input)
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

      def build_session
        manager = self.class.context_manager
        return nil unless manager

        Context::Session.new(
          messages: @session_messages ||= [],
          context_manager: manager,
          persisted_context: @context
        )
      end

      def resolve_agent_class(transition)
        return nil unless transition.agent_name

        Agent::Registry.find(transition.agent_name)
      end

      def execute_transition_body(transition, prepared_input: nil)
        @last_prepared_input = prepared_input

        return nil unless transition.agent_name

        Agent::Registry.find(transition.agent_name)
        nil
      end

      def execute_parallel_step(transition)
        count = resolve_branch_count(transition)
        branches = Array.new(count) do |i|
          build_branch(transition, i)
        end
        Parallel.execute(branches: branches)
      end

      def build_branch(transition, index)
        branch_ledger = @ledger
        proc do |signal|
          reservation = nil
          begin
            raise Smith::WorkflowError, "cancelled" if signal.cancelled?

            output = execute_transition_body(transition)

            raise Smith::WorkflowError, "cancelled" if signal.cancelled?

            { branch: index, agent: transition.agent_name, output: output }
          ensure
            # Budget release boundary for cancelled branches.
            # When real token/cost reservations are made during agent
            # execution, this ensure block is where release! will run
            # for cancelled branches per architecture §4.5/§5.2.
            branch_ledger&.release!(reservation.first, reservation.last) if reservation
          end
        end
      end

      def resolve_branch_count(transition)
        count = transition.agent_opts[:count]
        count.respond_to?(:call) ? count.call(@context) : (count || 1)
      end

      def handle_step_failure(transition, _error)
        failure_name = transition.failure_transition
        return unless failure_name

        fail_transition = self.class.find_transition(failure_name)
        return unless fail_transition

        @state = fail_transition.to
      end

      def emit_step_completed(transition, _output)
        Smith::Events.emit(
          Events::StepCompleted.new(
            transition: transition.name,
            from: transition.from,
            to: transition.to
          )
        )
      end
    end
  end
end
