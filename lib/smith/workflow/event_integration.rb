# frozen_string_literal: true

module Smith
  class Workflow
    module EventIntegration
      private

      def emit_step_completed(transition, _output)
        Smith::Trace.record(
          type: :transition,
          data: { transition: transition.name, from: transition.from, to: transition.to }
        )

        Smith::Events.emit(
          Events::StepCompleted.new(
            transition: transition.name.to_sym,
            from: transition.from&.to_sym,
            to: transition.to.to_sym,
            workflow: Attribution.ambient.workflow
          )
        )
      end

      # Failure-path counterpart to emit_step_completed, fired from both
      # failure handlers before they branch or re-raise, so an observer sees
      # exactly where execution went dark. Classification reuses
      # FailureRecord's bounded taxonomy; raw messages are never emitted. The
      # rescue keeps a broken instrument from altering failure semantics:
      # the original error, not an emission error, must win.
      def emit_step_failed(step)
        failure = FailureRecord.capture(step)
        record_failed_transition_trace(failure)
        emit_step_failed_event(failure)
      rescue StandardError => e
        Smith.config.logger&.error("Smith failed-step emission error: #{e.message}")
      end

      # `outcome`, not `result`: `result` is a reserved content key in the
      # trace pipeline (it carries tool results and is stripped by the
      # default content policy). Matches the :provider_call vocabulary.
      # `from`/`to` stay present even when nil, matching the success-trace
      # shape: an absent key would let the ambient attribution of an
      # enclosing scope (a parent step's `from`) show through the
      # fields-under-data merge and fabricate a foreign state fact.
      def record_failed_transition_trace(failure)
        data = {
          transition: failure[:transition], from: failure[:from], to: failure[:to],
          outcome: :failed,
          error_class: failure[:error_class],
          error_family: failure[:error_family]
        }
        data[:retryable] = failure[:error_retryable] unless failure[:error_retryable].nil?
        Smith::Trace.record(type: :transition, data: data)
      end

      def emit_step_failed_event(failure)
        Smith::Events.emit(
          Events::StepFailed.new(
            transition: DiagnosticText.capture(failure[:transition].to_s, max_bytes: 256).to_sym,
            from: failure[:from]&.to_sym,
            to: failure[:to]&.to_sym,
            error_class: failure[:error_class],
            error_family: failure[:error_family],
            retryable: failure[:error_retryable],
            workflow: Attribution.ambient.workflow
          )
        )
      end
    end
  end
end
