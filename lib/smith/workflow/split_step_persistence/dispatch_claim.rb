# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module DispatchClaim
        def claim_prepared_step_dispatch!
          ensure_restart_safe_dispatch_claim!
          ensure_split_step_definition_current!
          transaction_identity = TransactionIdentity.capture(@split_step_adapter)
          claim_dispatch_intent!
          payload, descriptor = build_split_step_dispatch_claim
          dispatch_started = true
          replace_exact_dispatch!(payload)
          accept_split_step_dispatch!(payload, descriptor, transaction_identity)
          descriptor
        rescue PersistencePayloadConflict
          reject_split_step_dispatch!
          raise
        rescue StandardError
          if dispatch_started
            mark_split_step_dispatch_unknown!(payload, descriptor)
          else
            restore_unclaimed_dispatch!
          end
          raise
        end

        private

        def ensure_restart_safe_dispatch_claim!
          return if restart_safe_split_step?

          raise WorkflowError, "restart-safe dispatch claiming requires a definition_digest"
        end

        def split_step_dispatch_payload(token)
          document = JSON.parse(@split_step_preparation_payload)
          document["split_step_phase"] = "dispatching"
          document["split_step_dispatch_token"] = token
          JSON.generate(document)
        end

        def build_split_step_dispatch_claim
          token = SecureRandom.uuid.freeze
          payload = split_step_dispatch_payload(token)
          [payload, build_split_step_dispatch(token, payload)]
        end

        def replace_exact_dispatch!(payload)
          @split_step_adapter.replace_exact(
            @split_step_persistence_key,
            payload,
            expected_payload: @split_step_preparation_payload,
            ttl: nil
          )
        end

        def build_split_step_dispatch(token, payload)
          PreparedStepDispatch.new(
            prepared_step: @split_step_prepared_descriptor,
            token:,
            dispatch_digest: CanonicalPayloadDigest.call(payload)
          )
        end

        def accept_split_step_dispatch!(payload, descriptor, transaction_identity)
          @split_step_mutex.synchronize do
            unless active_split_step_dispatch_claim?
              raise WorkflowError, "the prepared dispatch claim is no longer active"
            end

            @split_step_pre_dispatch_payload = @split_step_preparation_payload
            @split_step_preparation_payload = payload.freeze
            @split_step_dispatch_token = descriptor.token
            @split_step_dispatch_descriptor = descriptor
            @split_step_dispatch_thread = nil
            @split_step_phase = transaction_identity ? :dispatch_claimed_uncommitted : :dispatch_claimed
          end
        end

        def reject_split_step_dispatch!
          @split_step_mutex.synchronize do
            next unless active_split_step_dispatch_claim?

            @split_step_dispatch_thread = nil
            @split_step_phase = :dispatch_rejected
          end
        end

        def restore_unclaimed_dispatch!
          @split_step_mutex.synchronize do
            next unless active_split_step_dispatch_claim?

            @split_step_dispatch_thread = nil
            @split_step_phase = :prepared
          end
        end

        def mark_split_step_dispatch_unknown!(payload, descriptor)
          @split_step_mutex.synchronize do
            next unless active_split_step_dispatch_claim?

            @split_step_attempted_dispatch_payload = payload&.freeze
            @split_step_dispatch_token = descriptor&.token
            @split_step_attempted_dispatch_descriptor = descriptor
            @split_step_dispatch_thread = nil
            @split_step_phase = :dispatch_unknown
          end
        end

        def active_split_step_dispatch_claim?
          @split_step_phase == :claiming_dispatch && @split_step_dispatch_thread.equal?(Thread.current)
        end
      end
    end
  end
end
