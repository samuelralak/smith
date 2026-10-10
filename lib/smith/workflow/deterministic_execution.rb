# frozen_string_literal: true

module Smith
  class Workflow
    module DeterministicExecution
      private

      def execute_deterministic_step(transition)
        check_deadline!
        step = build_deterministic_step(transition)
        emit_deterministic_trace(transition, outcome: :started)
        transition.deterministic_block.call(step)
        ensure_deterministic_routed!(transition, step)
        apply_deterministic_writes!(step)
        emit_deterministic_trace(
          transition,
          outcome: step.routed_to ? :routed : :success,
          routed_to: step.routed_to,
          outcome_kind: step.outcome&.dig(:kind)
        )
        nil
      rescue StandardError => e
        emit_deterministic_trace(transition, outcome: :failed, failure: deterministic_failure_fields(transition, e))
        raise
      end

      # The bounded classification failed :transition traces carry, never
      # the raw message, which may hold content.
      def deterministic_failure_fields(transition, error)
        failure = FailureRecord.capture({ transition: transition.name, from: transition.from, to: transition.to,
                                          error: error })
        fields = { error_class: failure[:error_class], error_family: failure[:error_family] }
        fields[:retryable] = failure[:error_retryable] unless failure[:error_retryable].nil?
        fields
      end

      # A step declaring `routes:` must route, unless it declares `on_success`
      # or opts into `fallthrough: true`; otherwise the run would silently
      # take the first transition from the target state. Raised before any
      # write is applied, like any failing step.
      def ensure_deterministic_routed!(transition, step)
        return if step.routed_to || transition.deterministic_routes.nil?
        return if transition.deterministic_fallthrough || transition.success_transition

        raise UnroutedDeterministicStep.new(transition: transition.name, routes: transition.deterministic_routes)
      end

      def build_deterministic_step(transition)
        DeterministicStep.new(
          context: snapshot_value(@context),
          session_messages: snapshot_value(@session_messages || []),
          tool_results: snapshot_value(@tool_results || []),
          state: @state,
          transition: transition,
          last_agent_execution: snapshot_value(@last_agent_execution),
          persisted_keys: declared_persist_keys
        )
      end

      # The explicit `persist :a, :b` list a deterministic write must stay
      # within, or nil when the workflow declares none or uses `persist :auto`.
      def declared_persist_keys
        keys = resolve_persist_keys
        keys.is_a?(Array) ? keys : nil
      end

      def apply_deterministic_writes!(step)
        @context.merge!(symbolize_value(snapshot_value(step.context_writes)))
        step.context_writes.each_key { |key| record_persisted_key!(key) }
        @router_next_transition = step.routed_to if step.routed_to
        @outcome = symbolize_value(snapshot_value(step.outcome)) if step.outcome
      end

      # `outcome`, not `result`: `result` is a reserved content key that the
      # default content policy strips, matching the :transition and
      # :provider_call vocabulary.
      def emit_deterministic_trace(transition, outcome:, routed_to: nil, failure: nil, outcome_kind: nil)
        data = { transition: transition.name, from: transition.from, to: transition.to,
                 kind: transition.deterministic_kind, outcome: outcome }
        data[:routed_to] = routed_to if routed_to
        data.merge!(failure) if failure
        data[:outcome_kind] = outcome_kind if outcome_kind
        Smith::Trace.record(type: :deterministic_step, data: data)
      end
    end
  end
end
