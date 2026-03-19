# frozen_string_literal: true

module Smith
  class Workflow
    module Execution
      include Agent::Lifecycle

      private

      def execute_step(transition)
        agent_class = resolve_agent_class(transition)
        output = with_scoped_artifacts { run_guarded_step(transition, agent_class) }
        complete_step(transition, output)
      rescue StandardError => e
        handle_step_failure(transition, e)
        { transition: transition.name, from: transition.from, to: transition.to, error: e }
      ensure
        Tool.current_guardrails = nil
        Smith.scoped_artifacts = nil
      end

      def run_guarded_step(transition, agent_class)
        run_input_guardrails(agent_class)
        apply_tool_guardrails(agent_class)
        session = build_session
        prepared_input = session&.prepare!

        output = if transition.parallel?
                   execute_parallel_step(transition, prepared_input: prepared_input)
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

      def resolve_agent_class(transition)
        return nil unless transition.agent_name

        Agent::Registry.find(transition.agent_name)
      end

      def execute_transition_body(transition, prepared_input: nil)
        @last_prepared_input = prepared_input

        return nil unless transition.agent_name

        agent_class = Agent::Registry.find(transition.agent_name)
        return nil unless agent_class
        return nil if agent_class.chat_kwargs[:model].nil?

        invoke_agent(agent_class, prepared_input)
      end

      def invoke_agent(agent_class, prepared_input)
        chat = agent_class.chat

        prepared_input&.each { |msg| chat.add_message(msg) }

        schema = agent_class.output_schema
        chat = chat.with_schema(schema) if schema

        response = chat.complete
        result = response&.content

        run_after_completion(agent_class, result, @context)
      end

      def execute_parallel_step(transition, prepared_input: nil)
        guardrail_sources = Tool.current_guardrails
        scoped_store = propagate_scoped_artifacts
        count = Parallel.resolve_branch_count(transition, @context)
        branches = Array.new(count) do |i|
          build_branch(transition, i,
                       prepared_input: prepared_input,
                       guardrail_sources: guardrail_sources,
                       scoped_store: scoped_store)
        end
        Parallel.execute(branches: branches)
      end

      def build_branch(transition, index, prepared_input: nil, guardrail_sources: nil, scoped_store: nil)
        branch_ledger = @ledger
        proc do |signal|
          setup_branch_thread(guardrail_sources, scoped_store)
          reserved = reserve_branch_budget(branch_ledger)
          begin
            raise Smith::WorkflowError, "cancelled" if signal.cancelled?

            output = execute_transition_body(transition, prepared_input: prepared_input)
            raise Smith::WorkflowError, "cancelled" if signal.cancelled?

            reconcile_branch_budget(branch_ledger, reserved)
            reserved = nil
            { branch: index, agent: transition.agent_name, output: output }
          ensure
            release_branch_budget(branch_ledger, reserved) if reserved
            teardown_branch_thread
          end
        end
      end

      def setup_branch_thread(guardrail_sources, scoped_store)
        Tool.current_guardrails = guardrail_sources
        Smith.scoped_artifacts = scoped_store
      end

      def teardown_branch_thread
        Tool.current_guardrails = nil
        Smith.scoped_artifacts = nil
      end

      def handle_step_failure(transition, _error)
        failure_name = transition.failure_transition
        return unless failure_name

        fail_transition = self.class.find_transition(failure_name)
        return unless fail_transition

        @state = fail_transition.to
      end
    end
  end
end
