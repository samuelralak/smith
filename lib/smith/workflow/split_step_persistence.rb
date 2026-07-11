# frozen_string_literal: true

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
      include Execution
      include CheckpointState
      include Checkpoint
      include Payloads
    end
  end
end
