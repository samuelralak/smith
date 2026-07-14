# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Preparation
        DESCRIPTOR_PHASES = %i[
          prepared_uncommitted prepared verifying_execution execution_authorized executing executed attempted
          dispatch_claimed_uncommitted dispatch_claimed dispatch_rejected dispatch_unknown
          confirming_dispatch checkpointing checkpoint_retryable checkpoint_unknown
          checkpointed confirming_checkpoint
        ].freeze
        private_constant :DESCRIPTOR_PHASES

        def prepare_persisted_step!(key = nil, adapter: Smith.persistence_adapter)
          ensure_strict_split_step_persistence!
          intent_claimed = claim_split_step_preparation_intent!
          return unless intent_claimed

          preparation_finalized = false
          prepare_claimed_persisted_step!(key, adapter)
          preparation_finalized = true
          persist_claimed_split_step_preparation!(@split_step_persistence_key, @split_step_adapter)
          @split_step_transition_name
        ensure
          release_split_step_preparation_intent! if intent_claimed && !preparation_finalized
        end

        def confirm_prepared_step!
          confirmation_claimed = false
          claim_split_step_confirmation!
          confirmation_claimed = true
          confirmed = false
          payload = @split_step_adapter.fetch(@split_step_persistence_key)
          raise WorkflowError, "the persisted split-step preparation is not committed" unless
            persisted_split_step_payload?(payload, @split_step_preparation_payload)

          @split_step_mutex.synchronize do
            @split_step_phase = :prepared
            @split_step_transaction_thread = nil
            @split_step_transaction_identity = nil
          end
          confirmed = true
          self
        ensure
          restore_unconfirmed_preparation! if confirmation_claimed && !confirmed
        end

        def prepared_persisted_step
          phase, descriptor, adapter, transaction_identity = @split_step_mutex.synchronize do
            [
              @split_step_phase,
              @split_step_prepared_descriptor,
              @split_step_adapter,
              @split_step_transaction_identity
            ]
          end
          return unless DESCRIPTOR_PHASES.include?(phase) && descriptor
          return descriptor unless phase == :prepared_uncommitted

          descriptor if TransactionIdentity.matches?(adapter, transaction_identity)
        end

        private

        def ensure_strict_split_step_persistence!
          return if strict_idempotency?

          raise WorkflowError, "split-step persistence requires idempotency_mode :strict"
        end

        def prepare_claimed_persisted_step!(key, adapter)
          transition = pending_split_step_transition
          transition_name = @next_transition_name || transition&.name
          raise WorkflowError, "workflow has no pending transition" unless transition_name

          ensure_transition_budget!
          resolved_key = normalize_split_step_persistence_key(candidate_split_step_persistence_key(key))
          store = persistence_adapter!(adapter)
          persistence_ttl = validate_split_step_adapter!(store)
          finalize_split_step_preparation!(transition, transition_name, resolved_key, store, persistence_ttl)
        end

        def pending_split_step_transition
          transition = if @next_transition_name
                         self.class.find_transition(@next_transition_name)
                       else
                         self.class.first_transition_from(@state)
                       end
          validate_transition_origin!(transition) if transition
          transition
        end

        def candidate_split_step_persistence_key(key)
          return key unless key.nil? || blank_key?(key)
          return @persistence_key unless blank_key?(@persistence_key)

          self.class.send(:resolve_persistence_key!, key:, context: @context)
        end

        def normalize_split_step_persistence_key(key) = key.to_s.dup.freeze

        def validate_split_step_adapter!(adapter)
          unless Smith::PersistenceAdapters.supports?(adapter, :store_versioned)
            raise WorkflowError, "split-step persistence requires an adapter with store_versioned"
          end

          validate_restart_safe_adapter!(adapter)
          unless split_step_adapter_accepts_explicit_ttl?(adapter)
            raise WorkflowError, "split-step persistence requires store_versioned to accept ttl:"
          end
          return unless effective_persistence_ttl

          raise WorkflowError, "split-step persistence requires non-expiring workflow persistence"
        end

        def split_step_adapter_accepts_explicit_ttl?(adapter)
          adapter.method(:store_versioned).parameters.any? do |kind, name|
            kind == :keyrest || (%i[key keyreq].include?(kind) && name == :ttl)
          end
        end
      end
    end
  end
end
