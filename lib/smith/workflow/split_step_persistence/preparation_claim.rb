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
            true
          end
        end

        def release_split_step_preparation_intent!
          @split_step_mutex.synchronize do
            next unless @split_step_phase == :claiming_preparation
            next unless @split_step_preparation_thread.equal?(Thread.current)

            @split_step_phase = nil
            @split_step_preparation_thread = nil
          end
        end

        def finalize_split_step_preparation!(transition, transition_name, key, adapter, persistence_ttl)
          @split_step_mutex.synchronize do
            unless active_split_step_preparation_claim?
              raise WorkflowError, "the split-step preparation claim is no longer active"
            end

            @split_step_phase = :preparing
            @split_step_transition_name = transition_name
            @split_step_transition = transition
            @split_step_transition_signature = split_step_transition_signature(transition)
            @split_step_origin_state = @state
            @split_step_token = SecureRandom.uuid.freeze
            deep_freeze_split_step_value(transition)
            detach_split_step_execution_state!
            @split_step_persistence_key = key
            @split_step_adapter = adapter
            @split_step_persistence_ttl = persistence_ttl
            @persistence_key = key
            @split_step_persist_permit = true
          end
        end

        def active_split_step_preparation_claim?
          @split_step_phase == :claiming_preparation &&
            @split_step_preparation_thread.equal?(Thread.current)
        end

        def mark_split_step_prepared!(adapter)
          @split_step_mutex.synchronize do
            @split_step_phase = if Smith::PersistenceAdapters.supports?(adapter, :transaction_open?) &&
                                   adapter.transaction_open?
                                  :prepared_uncommitted
                                else
                                  :prepared
                                end
            @split_step_preparation_thread = nil
            @split_step_persist_permit = false
          end
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
