# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Checkpoint
        def complete_persisted_step!
          completion_claimed = false
          previous_phase = claim_split_step_completion!
          completion_claimed = true
          completed = false
          payload = @split_step_adapter.fetch(@split_step_persistence_key)
          unless persisted_split_step_checkpoint?(payload)
            recover_rolled_back_split_step_checkpoint!(payload)
            raise WorkflowError, "the persisted split-step checkpoint is not committed"
          end

          @split_step_mutex.synchronize do
            @persistence_version = @split_step_checkpoint_version
            clear_step_in_progress!
            clear_split_step_boundary!
          end
          completed = true
          self
        ensure
          restore_incomplete_checkpoint!(previous_phase) if completion_claimed && !completed
        end

        def persist!(key = nil, adapter: Smith.persistence_adapter)
          checkpoint_claimed = false
          resolved_key, store = resolve_split_step_target(key, adapter)
          checkpoint_claimed = claim_split_step_checkpoint!
          result = super(resolved_key, adapter: store) do |payload, next_version|
            capture_split_step_payload!(payload, next_version, checkpoint_claimed:)
          end
          @split_step_mutex.synchronize { @split_step_phase = :checkpointed } if checkpoint_claimed
          result
        rescue StandardError
          mark_split_step_checkpoint_unknown! if checkpoint_claimed
          raise
        end

        private

        def resolve_split_step_target(key, adapter)
          resolved_key = if @split_step_persistence_key
                           candidate = candidate_split_step_persistence_key(key)
                           if candidate.equal?(@split_step_persistence_key)
                             candidate
                           else
                             normalize_split_step_persistence_key(candidate)
                           end
                         else
                           resolve_persistence_key!(key)
                         end
          store = persistence_adapter!(adapter)
          validate_split_step_target!(resolved_key, store)
          resolved_key = @split_step_persistence_key if @split_step_persistence_key
          @persistence_key = resolved_key
          [resolved_key, store]
        end

        def claim_split_step_checkpoint!
          @split_step_mutex.synchronize do
            if split_step_preparation_persist_permitted?
              @split_step_persist_permit = false
              return false
            end
            return false unless @split_step_phase

            if %i[executed checkpoint_retryable].include?(@split_step_phase)
              @split_step_phase = :checkpointing
              return true
            end

            raise WorkflowError, "the active split-step boundary cannot be checkpointed"
          end
        end

        def split_step_preparation_persist_permitted?
          @split_step_phase == :preparing &&
            @split_step_preparation_thread.equal?(Thread.current) &&
            @split_step_persist_permit
        end

        def validate_split_step_target!(key, adapter)
          return unless @split_step_persistence_key
          return if key == @split_step_persistence_key && adapter.equal?(@split_step_adapter)

          raise WorkflowError, "the split-step persistence target cannot change"
        end

        def capture_split_step_payload!(payload, next_version, checkpoint_claimed:)
          return capture_split_step_preparation_payload!(payload, next_version) if @split_step_phase == :preparing

          validate_split_step_marker!(payload, expected: true) if checkpoint_claimed
          return payload unless checkpoint_claimed

          checkpoint_payload = split_step_checkpoint_payload(payload)
          checkpoint_digest = Digest::SHA256.hexdigest(checkpoint_payload)
          validate_split_step_retry_payload!(checkpoint_digest)
          @split_step_checkpoint_digest = checkpoint_digest
          @split_step_checkpoint_version = next_version
          checkpoint_payload
        end

        def validate_split_step_retry_payload!(checkpoint_digest)
          return unless @split_step_checkpoint_digest
          return if @split_step_checkpoint_digest == checkpoint_digest

          @split_step_mutex.synchronize do
            @split_step_phase = :checkpoint_retryable if @split_step_phase == :checkpointing
          end
          raise WorkflowError, "the reconciled split-step checkpoint payload changed"
        end
      end
    end
  end
end
