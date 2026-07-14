# frozen_string_literal: true

require "dry-struct"

require_relative "../types"
require_relative "prepared_step"
require_relative "prepared_step_dispatch"

module Smith
  class Workflow
    class PreparedStepRecovery < Dry::Struct
      attribute :prepared_step, Types.Instance(PreparedStep)
      attribute? :dispatch_claim, Types.Instance(PreparedStepDispatch).optional
      attribute :execution_status, Types::Symbol.enum(:not_started)

      def self.not_started(witness)
        case witness
        when PreparedStep
          new(prepared_step: witness, dispatch_claim: nil, execution_status: :not_started)
        when PreparedStepDispatch
          new(prepared_step: witness.prepared_step, dispatch_claim: witness, execution_status: :not_started)
        else
          raise ArgumentError, "recovery witness must be a PreparedStep or PreparedStepDispatch"
        end
      end

      def initialize(attributes)
        super
        if dispatch_claim && dispatch_claim.prepared_step.to_h != prepared_step.to_h
          raise ArgumentError, "dispatch claim must belong to the prepared step"
        end

        self.attributes.freeze
        freeze
      end
    end
  end
end
