# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module PreparationClaim
        private

        def claim_split_step_preparation_intent!
          @split_step_mutex.synchronize do
            ensure_no_split_step_boundary!
            return false if terminal?

            @split_step_phase = :claiming_preparation
            @split_step_preparation_thread = Thread.current
            @split_step_definition_digest = self.class.definition_digest
            true
          end
        end

        def release_split_step_preparation_intent!
          @split_step_mutex.synchronize do
            next unless @split_step_phase == :claiming_preparation
            next unless @split_step_preparation_thread.equal?(Thread.current)

            @split_step_phase = nil
            @split_step_preparation_thread = nil
            remove_instance_variable(:@split_step_definition_digest) if
              instance_variable_defined?(:@split_step_definition_digest)
          end
        end

        def finalize_split_step_preparation!(transition, transition_name, key, adapter, persistence_ttl)
          transaction_identity = TransactionIdentity.capture(adapter)
          transition_signature = TransitionContract.capture(transition)
          @split_step_mutex.synchronize do
            unless active_split_step_preparation_claim?
              raise WorkflowError, "the split-step preparation claim is no longer active"
            end

            @split_step_phase = :preparing
            @split_step_transition_name = transition_name
            @split_step_transition = transition
            @split_step_transition_signature = transition_signature
            @split_step_origin_state = @state
            @split_step_token = SecureRandom.uuid.freeze
            detach_split_step_execution_state!
            target_writer = PreparationClaim.instance_method(:assign_split_step_persistence_target!)
            target_writer.bind_call(self, key, adapter, persistence_ttl, transaction_identity)
          end
        end

        def assign_split_step_persistence_target!(key, adapter, persistence_ttl, transaction_identity)
          @split_step_persistence_key = key
          @split_step_adapter = adapter
          @split_step_persistence_ttl = persistence_ttl
          @split_step_transaction_identity = transaction_identity
          @split_step_dispatch_started = false
          @persistence_key = key
          @split_step_persist_permit = true
        end

        def active_split_step_preparation_claim?
          @split_step_phase == :claiming_preparation &&
            @split_step_preparation_thread.equal?(Thread.current)
        end

        def mark_split_step_prepared!(_adapter)
          @split_step_mutex.synchronize do
            phase = @split_step_transaction_identity ? :prepared_uncommitted : :prepared
            unless @split_step_pending_descriptor
              raise WorkflowError, "split-step preparation descriptor was not captured"
            end

            @split_step_prepared_descriptor = @split_step_pending_descriptor
            @split_step_pending_descriptor = nil
            @split_step_phase = phase
            @split_step_preparation_thread = nil
            @split_step_persist_permit = false
          end
        end

        def build_split_step_prepared_descriptor(persistence_version)
          PreparedStep.new(
            token: @split_step_token,
            transition: @split_step_transition_name.to_s,
            from: @split_step_origin_state.to_s,
            persistence_key: @split_step_persistence_key,
            persistence_version: persistence_version,
            step_number: @step_count + 1,
            preparation_digest: @split_step_preparation_digest,
            definition_digest: effective_definition_digest
          )
        end

        def claim_split_step_confirmation!
          @split_step_mutex.synchronize do
            unless @split_step_phase == :prepared_uncommitted
              raise WorkflowError, "no uncommitted split-step preparation is awaiting confirmation"
            end
            if @split_step_adapter.transaction_open?
              raise WorkflowError, "the split-step preparation transaction is still open"
            end

            @split_step_phase = :confirming_preparation
          end
        end

        def restore_unconfirmed_preparation!
          @split_step_mutex.synchronize do
            @split_step_phase = :prepared_uncommitted if @split_step_phase == :confirming_preparation
          end
        end
      end
    end
  end
end
