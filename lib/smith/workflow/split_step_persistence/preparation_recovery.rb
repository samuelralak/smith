# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module PreparationRecovery
        private

        def persist_claimed_split_step_preparation!(resolved_key, store)
          persist!(resolved_key, adapter: store)
          mark_split_step_prepared!(store)
        rescue PersistenceVersionConflict
          handle_split_step_preparation_conflict!
          raise
        rescue StandardError
          mark_split_step_preparation_unknown!
          raise
        end

        def reset_failed_split_step_preparation!
          return unless @split_step_phase == :preparing

          clear_step_in_progress!
          clear_split_step_boundary!
        end

        def handle_split_step_preparation_conflict!
          payload = @split_step_adapter.fetch(@split_step_persistence_key)
          if persisted_split_step_payload?(payload, @split_step_preparation_payload)
            mark_split_step_preparation_unknown!
          else
            reset_failed_split_step_preparation!
          end
        rescue StandardError
          mark_split_step_preparation_unknown!
        end

        def mark_split_step_preparation_unknown!
          @split_step_mutex.synchronize do
            @split_step_phase = :preparation_unknown if @split_step_phase == :preparing
          end
        end
      end
    end
  end
end
