# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module DispatchVerification
        private

        def claim_dispatch_intent!
          @split_step_mutex.synchronize do
            raise WorkflowError, "no persisted step is prepared" unless @split_step_phase == :prepared

            ensure_prepared_split_step_transition_matches!
            @split_step_phase = :claiming_dispatch
            @split_step_dispatch_thread = Thread.current
          end
        end

        def verify_split_step_dispatch_available!(verification_token)
          payload = @split_step_adapter.fetch(@split_step_persistence_key)
          return if persisted_split_step_payload?(payload, @split_step_preparation_payload)

          @split_step_mutex.synchronize do
            if active_split_step_execution_verification?(verification_token)
              @split_step_phase = :dispatch_unknown
              @split_step_execution_previous_phase = nil
              clear_split_step_execution_verification!
            end
          end
          raise PersistencePayloadConflict.new(key: @split_step_persistence_key)
        end
      end
    end
  end
end
