# frozen_string_literal: true

require "dry/initializer"

require_relative "payload_digest"

module Smith
  class Workflow
    module Composite
      class PlanIntegrity
        extend Dry::Initializer

        param :plan

        def call
          validate_execution_semantics!
          validate_branches!
          validate_digest!
          plan
        end

        private

        def validate_execution_semantics!
          return if plan.execution_semantics_version == Smith::EXECUTION_SEMANTICS_VERSION

          raise ArgumentError, "composite plan execution semantics do not match"
        end

        def validate_branches!
          keys = {}
          plan.branches.each_with_index do |branch, ordinal|
            raise ArgumentError, "composite plan ordinals must be contiguous" unless branch.ordinal == ordinal
            raise ArgumentError, "composite plan branch keys must be unique" if keys.key?(branch.key)

            keys[branch.key] = true
          end
        end

        def validate_digest!
          attributes = plan.to_h.except(:plan_digest).merge(
            dispatch: plan.dispatch.to_h,
            branches: plan.branches.map(&:to_h)
          )
          return if plan.plan_digest == PayloadDigest.call(attributes)

          raise ArgumentError, "composite plan digest does not match"
        end
      end
    end
  end
end
