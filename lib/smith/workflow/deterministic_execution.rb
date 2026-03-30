# frozen_string_literal: true

module Smith
  class Workflow
    module DeterministicExecution
      private

      def execute_deterministic_step(transition)
        check_deadline!
        step = build_deterministic_step(transition)
        emit_deterministic_trace(transition, result: :started)
        transition.deterministic_block.call(step)
        apply_deterministic_writes!(step)
        emit_deterministic_trace(transition, result: step.routed_to ? :routed : :success,
                                 routed_to: step.routed_to)
        nil
      rescue StandardError => e
        emit_deterministic_trace(transition, result: :failed, error: e.message)
        raise
      end

      def build_deterministic_step(transition)
        DeterministicStep.new(
          context: snapshot_value(@context),
          session_messages: snapshot_value(@session_messages || []),
          tool_results: snapshot_value(@tool_results || []),
          state: @state,
          transition_name: transition.name
        )
      end

      def apply_deterministic_writes!(step)
        @context.merge!(step.context_writes)
        @router_next_transition = step.routed_to if step.routed_to
      end

      def emit_deterministic_trace(transition, result:, routed_to: nil, error: nil)
        data = { transition: transition.name, from: transition.from, to: transition.to,
                 kind: transition.deterministic_kind, result: result }
        data[:routed_to] = routed_to if routed_to
        data[:error] = error if error
        Smith::Trace.record(type: :deterministic_step, data: data)
      end
    end
  end
end
