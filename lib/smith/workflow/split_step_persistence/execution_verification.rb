# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module ExecutionVerification
        private

        def claim_split_step_execution_verification!
          @split_step_mutex.synchronize do
            DefinitionBoundary
              .instance_method(:ensure_split_step_definition_current!)
              .bind_call(self)
            restart_safe = DefinitionBoundary
                           .instance_method(:restart_safe_split_step?)
                           .bind_call(self)
            expected = restart_safe ? :dispatch_claimed : :prepared
            raise WorkflowError, "no persisted step is prepared for execution" unless @split_step_phase == expected

            ExecutionVerification
              .instance_method(:ensure_prepared_split_step_transition_matches!)
              .bind_call(self)

            token = Object.new.freeze
            @split_step_execution_previous_phase = expected
            @split_step_execution_verification_token = token
            @split_step_phase = :verifying_execution
            token
          end
        end

        def verify_claimed_split_step_execution!(verification_token)
          restart_safe = DefinitionBoundary
                         .instance_method(:restart_safe_split_step?)
                         .bind_call(self)
          if restart_safe
            DispatchVerification
              .instance_method(:verify_split_step_dispatch_available!)
              .bind_call(self, verification_token)
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
