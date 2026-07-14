# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module BoundaryReset
        private

        def clear_split_step_boundary!
          @split_step_phase = nil
          @split_step_transition_name = nil
          @split_step_transition = nil
          @split_step_transition_signature = nil
          @split_step_origin_state = nil
          @split_step_token = nil
          @split_step_active_execution_authorization = nil
          @split_step_execution_result = nil
          clear_split_step_descriptor_state!
          @split_step_persistence_key = nil
          @split_step_adapter = nil
          remove_instance_variable(:@split_step_persistence_ttl) if
            instance_variable_defined?(:@split_step_persistence_ttl)
          @split_step_preparation_payload = nil
          @split_step_checkpoint_digest = nil
          @split_step_checkpoint_version = nil
          @split_step_preparation_thread = nil
          @split_step_persist_permit = false
        end

        def clear_split_step_descriptor_state!
          @split_step_prepared_descriptor = nil
          @split_step_transaction_identity = nil
          @split_step_preparation_digest = nil
          @split_step_pending_descriptor = nil
          @split_step_dispatch_started = false
          @split_step_dispatch_token = nil
          @split_step_dispatch_descriptor = nil
          @split_step_attempted_dispatch_descriptor = nil
          @split_step_dispatch_thread = nil
          @split_step_pre_dispatch_payload = nil
          @split_step_attempted_dispatch_payload = nil
          clear_split_step_execution_verification!
          clear_split_step_execution_authorization!
          remove_instance_variable(:@split_step_definition_digest) if
            instance_variable_defined?(:@split_step_definition_digest)
        end
      end
    end
  end
end
