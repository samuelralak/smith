# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

require_relative "prepared_step"
require_relative "prepared_step_dispatch"
require_relative "prepared_step_execution_authorization"
require_relative "prepared_step_execution_result"
require_relative "prepared_step_recovery"
require_relative "split_step_persistence/subclass_boundary"
require_relative "split_step_persistence/inheritance"
require_relative "split_step_persistence/recovery_class_methods"
require_relative "split_step_persistence/transition_contract_structured_values"
require_relative "split_step_persistence/transition_contract_signature"
require_relative "split_step_persistence/transition_contract_freezer"
require_relative "split_step_persistence/transition_contract"
require_relative "split_step_persistence/transaction_identity"
require_relative "split_step_persistence/canonical_payload_digest"
require_relative "split_step_persistence/definition_boundary"
require_relative "split_step_persistence/boundary"
require_relative "split_step_persistence/boundary_reset"
require_relative "split_step_persistence/state_snapshot"
require_relative "split_step_persistence/preparation_claim"
require_relative "split_step_persistence/preparation_recovery"
require_relative "split_step_persistence/preparation"
require_relative "split_step_persistence/restart_safe_adapter"
require_relative "split_step_persistence/recovery"
require_relative "split_step_persistence/recovery_boundary"
require_relative "split_step_persistence/preparation_payload"
require_relative "split_step_persistence/dispatch_boundary"
require_relative "split_step_persistence/dispatch_claim"
require_relative "split_step_persistence/dispatch_verification"
require_relative "split_step_persistence/dispatch_confirmation"
require_relative "split_step_persistence/execution_verification"
require_relative "split_step_persistence/execution_binding_snapshot"
require_relative "split_step_persistence/execution_authorization"
require_relative "split_step_persistence/execution_authorization_issuance"
require_relative "split_step_persistence/execution_result_capture"
require_relative "split_step_persistence/execution_lifecycle"
require_relative "split_step_persistence/composite_preparation"
require_relative "split_step_persistence/composite_branch_authorization"
require_relative "split_step_persistence/composite_branch_execution"
require_relative "split_step_persistence/composite_reduction_execution"
require_relative "split_step_persistence/composite_execution"
require_relative "split_step_persistence/execution"
require_relative "split_step_persistence/checkpoint_state"
require_relative "split_step_persistence/checkpoint"
require_relative "split_step_persistence/payloads"

module Smith
  class Workflow
    module SplitStepPersistence
      NO_SPLIT_TRANSITION = Object.new.freeze

      def self.prepended(base)
        base.singleton_class.prepend(Inheritance)
        base.extend(RecoveryClassMethods)
      end

      include Boundary
      include BoundaryReset
      include DefinitionBoundary
      include StateSnapshot
      include PreparationClaim
      include PreparationRecovery
      include Preparation
      include RestartSafeAdapter
      include Recovery
      include RecoveryBoundary
      include PreparationPayload
      include DispatchBoundary
      include DispatchClaim
      include DispatchVerification
      include DispatchConfirmation
      include ExecutionVerification
      include ExecutionAuthorization
      include ExecutionAuthorizationIssuance
      include ExecutionResultCapture
      include ExecutionLifecycle
      include CompositePreparation
      include CompositeBranchAuthorization
      include CompositeBranchExecution
      include CompositeReductionExecution
      include CompositeExecution
      include Execution
      include CheckpointState
      include Checkpoint
      include Payloads
    end
  end
end
