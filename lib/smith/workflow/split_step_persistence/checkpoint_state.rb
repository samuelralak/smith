# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module CheckpointState
        private

        def claim_split_step_completion!
          @split_step_mutex.synchronize do
            unless %i[checkpoint_unknown checkpointed].include?(@split_step_phase)
              raise WorkflowError, "no persisted split-step checkpoint is awaiting completion"
            end
            if Smith::PersistenceAdapters.supports?(@split_step_adapter, :transaction_open?) &&
               @split_step_adapter.transaction_open?
              raise WorkflowError, "the split-step checkpoint transaction is still open"
            end

            previous_phase = @split_step_phase
            @split_step_phase = :confirming_checkpoint
            previous_phase
          end
        end

        def restore_incomplete_checkpoint!(previous_phase)
          @split_step_mutex.synchronize do
            @split_step_phase = previous_phase if @split_step_phase == :confirming_checkpoint
          end
        end

        def recover_rolled_back_split_step_checkpoint!(payload)
          return unless persisted_split_step_payload?(payload, @split_step_preparation_payload)

          preparation_version = JSON.parse(payload).fetch("persistence_version")
          @split_step_mutex.synchronize do
            return unless @split_step_phase == :confirming_checkpoint

            @persistence_version = preparation_version
            @split_step_phase = :checkpoint_retryable
          end
        end

        def mark_split_step_checkpoint_unknown!
          @split_step_mutex.synchronize do
            @split_step_phase = :checkpoint_unknown if @split_step_phase == :checkpointing
          end
        end
      end
    end
  end
end
