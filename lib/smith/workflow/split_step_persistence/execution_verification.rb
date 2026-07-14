# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module ExecutionVerification
        private

        def claim_split_step_execution_verification!
          @split_step_mutex.synchronize do
            ensure_split_step_definition_current!
            expected = restart_safe_split_step? ? :dispatch_claimed : :prepared
            raise WorkflowError, "no persisted step is prepared for execution" unless @split_step_phase == expected

            ensure_prepared_split_step_transition_matches!

            token = Object.new.freeze
            @split_step_execution_previous_phase = expected
            @split_step_execution_verification_token = token
            @split_step_phase = :verifying_execution
            token
          end
        end

        def verify_claimed_split_step_execution!(verification_token)
          if restart_safe_split_step?
            verify_split_step_dispatch_available!(verification_token)
          else
            verify_split_step_preparation_available!
          end
        end

        def prepared_split_step_transition_matches?
          transition = pending_split_step_transition
          transition_name = @next_transition_name || transition&.name
          transition_name == @split_step_transition_name &&
            transition.equal?(@split_step_transition) &&
            split_step_transition_signature(transition) == @split_step_transition_signature
        end

        def ensure_prepared_split_step_transition_matches!
          return if prepared_split_step_transition_matches?

          raise WorkflowError, "the prepared transition no longer matches the workflow"
        end

        def verify_split_step_preparation_available!
          payload = @split_step_adapter.fetch(@split_step_persistence_key)
          durable = persisted_split_step_payload?(payload, @split_step_preparation_payload)
          live = persisted_split_step_payload?(current_split_step_preparation_payload, @split_step_preparation_payload)
          stable = split_step_transition_signature(@split_step_transition) == @split_step_transition_signature
          return if durable && live && stable

          raise WorkflowError, "the persisted split-step preparation is no longer available"
        end

        def current_split_step_preparation_payload
          split_step_preparation_payload(
            JSON.generate(to_state.merge(persistence_version: @persistence_version))
          )
        end
      end
    end
  end
end
