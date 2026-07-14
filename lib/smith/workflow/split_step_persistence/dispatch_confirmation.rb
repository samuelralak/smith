# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module DispatchConfirmation
        def confirm_prepared_step_dispatch!
          confirmation_claimed = false
          rolled_back = false
          claim_dispatch_confirmation!
          confirmation_claimed = true
          payload = @split_step_adapter.fetch(@split_step_persistence_key)
          return confirm_committed_dispatch! if persisted_split_step_payload?(payload, @split_step_preparation_payload)

          rolled_back = recover_rolled_back_dispatch!(payload)
          raise WorkflowError, "the persisted split-step dispatch claim is not committed"
        rescue StandardError
          mark_unconfirmed_dispatch_unknown! if confirmation_claimed && !rolled_back
          raise
        end

        private

        def claim_dispatch_confirmation!
          @split_step_mutex.synchronize do
            unless @split_step_phase == :dispatch_claimed_uncommitted
              raise WorkflowError, "no uncommitted split-step dispatch claim is awaiting confirmation"
            end
            if @split_step_adapter.transaction_open?
              raise WorkflowError, "the split-step dispatch transaction is still open"
            end

            @split_step_phase = :confirming_dispatch
          end
        end

        def confirm_committed_dispatch!
          @split_step_mutex.synchronize do
            @split_step_phase = :dispatch_claimed
            clear_split_step_dispatch_transaction!
          end
          self
        end

        def recover_rolled_back_dispatch!(payload)
          return false unless persisted_split_step_payload?(payload, @split_step_pre_dispatch_payload)

          @split_step_mutex.synchronize do
            return false unless @split_step_phase == :confirming_dispatch

            @split_step_preparation_payload = @split_step_pre_dispatch_payload
            @split_step_phase = :prepared
            clear_split_step_dispatch_transaction!
            true
          end
        end

        def mark_unconfirmed_dispatch_unknown!
          @split_step_mutex.synchronize do
            @split_step_phase = :dispatch_unknown if @split_step_phase == :confirming_dispatch
          end
        end

        def clear_split_step_dispatch_transaction!
          @split_step_pre_dispatch_payload = nil
        end
      end
    end
  end
end
