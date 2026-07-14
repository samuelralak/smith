# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module RecoveryBoundary
        private

        def attach_recovered_split_step!(descriptor, payload, adapter, dispatch_claim:)
          transition = pending_split_step_transition
          transition_name = @next_transition_name || transition&.name
          unless transition && transition_name.to_s == descriptor.transition && @state.to_s == descriptor.from
            raise WorkflowError, "the recovered transition does not match the current workflow position"
          end

          detach_split_step_execution_state!
          install_recovered_split_step!(descriptor, payload, adapter, transition, dispatch_claim)
        end

        def install_recovered_split_step!(descriptor, payload, adapter, transition, dispatch_claim)
          signature = TransitionContract.capture(transition)
          @split_step_mutex.synchronize do
            install_recovered_transition!(transition, signature)
            install_recovered_persistence!(descriptor, payload, adapter)
            install_recovered_dispatch!(dispatch_claim)
          end
        end

        def install_recovered_transition!(transition, signature)
          @split_step_transition_name = transition.name
          @split_step_transition = transition
          @split_step_transition_signature = signature
          @split_step_origin_state = @state
        end

        def install_recovered_persistence!(descriptor, payload, adapter)
          @split_step_token = descriptor.token
          @split_step_prepared_descriptor = descriptor
          @split_step_persistence_key = descriptor.persistence_key
          @split_step_adapter = adapter
          @split_step_persistence_ttl = nil
          @split_step_preparation_payload = payload.dup.freeze
          @split_step_preparation_digest = descriptor.preparation_digest
          @split_step_definition_digest = descriptor.definition_digest
        end

        def install_recovered_dispatch!(dispatch_claim)
          @split_step_dispatch_started = false
          @split_step_dispatch_token = dispatch_claim&.token
          @split_step_dispatch_descriptor = dispatch_claim
          @split_step_phase = dispatch_claim ? :dispatch_claimed : :prepared
        end
      end
    end
  end
end
