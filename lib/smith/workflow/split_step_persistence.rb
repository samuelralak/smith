# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

require_relative "prepared_step"
require_relative "split_step_persistence/subclass_boundary"
require_relative "split_step_persistence/inheritance"
require_relative "split_step_persistence/transition_contract_structured_values"
require_relative "split_step_persistence/transition_contract_signature"
require_relative "split_step_persistence/transition_contract_freezer"
require_relative "split_step_persistence/transition_contract"
require_relative "split_step_persistence/transaction_identity"
require_relative "split_step_persistence/canonical_payload_digest"
require_relative "split_step_persistence/boundary"
require_relative "split_step_persistence/state_snapshot"
require_relative "split_step_persistence/preparation_claim"
require_relative "split_step_persistence/preparation_recovery"
require_relative "split_step_persistence/preparation"
require_relative "split_step_persistence/preparation_payload"
require_relative "split_step_persistence/dispatch_boundary"
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
      end

      include Boundary
      include StateSnapshot
      include PreparationClaim
      include PreparationRecovery
      include Preparation
      include PreparationPayload
      include DispatchBoundary
      include Execution
      include CheckpointState
      include Checkpoint
      include Payloads
    end
  end
end
