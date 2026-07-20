# frozen_string_literal: true

require_relative "../../types"
require_relative "../prepared_step"
require_relative "../prepared_step_dispatch"
require_relative "branch"
require_relative "enums"
require_relative "payload"
require_relative "payload_digest"
require_relative "plan"

module Smith
  class Workflow
    module Composite
      class BranchExecution < Payload
        VERSION = 1
        ENUM_ATTRIBUTES = %i[kind resume_policy failure_policy reduction_policy retry_policy].freeze
        private_constant :ENUM_ATTRIBUTES
        OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
        private_constant :OwnedString

        attribute :version, Types::Integer.enum(VERSION)
        attribute :execution_semantics_version, OwnedString.constrained(min_size: 1, max_size: 32)
        attribute :dispatch, Types.Instance(PreparedStepDispatch)
        attribute :plan_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :kind, Types::Symbol.enum(:parallel, :fanout)
        attribute :transition, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :from, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :execution_namespace, OwnedString.constrained(format: PreparedStep::UUID_PATTERN)
        attribute :branch_count, Types::Integer.constrained(gteq: 1, lteq: Plan::MAX_BRANCHES)
        attribute :input_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :budget_state_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :resume_policy, Types::Symbol.enum(Plan::RESUME_POLICY)
        attribute :failure_policy, Types::Symbol.enum(Plan::FAILURE_POLICY)
        attribute :reduction_policy, Types::Symbol.enum(Plan::REDUCTION_POLICY)
        attribute :retry_policy, Types::Symbol.enum(Plan::RETRY_POLICY)
        attribute :branch, Types.Instance(Branch)
        attribute :digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)

        class << self
          def build(plan:, branch:)
            validate_plan_branch!(plan, branch)
            values = execution_attributes(plan, branch)
            new(values.merge(digest: PayloadDigest.call(serializable(values))))
          end

          def normalize_attributes(attributes)
            normalized = super
            normalize_dispatch!(normalized)
            normalize_branch!(normalized)
            ENUM_ATTRIBUTES.each { |key| normalized[key] = Enums.normalize(key, normalized[key]) }
            normalized
          end

          def serializable(values)
            values.merge(dispatch: values.fetch(:dispatch).to_h, branch: values.fetch(:branch).to_h)
          end

          private

          def execution_attributes(plan, branch)
            {
              version: VERSION,
              execution_semantics_version: plan.execution_semantics_version,
              dispatch: plan.dispatch,
              plan_digest: plan.plan_digest,
              kind: plan.kind,
              transition: plan.transition,
              from: plan.from,
              execution_namespace: plan.execution_namespace,
              branch_count: plan.branches.length,
              input_digest: plan.input_digest,
              budget_state_digest: plan.budget_state_digest,
              resume_policy: plan.resume_policy,
              failure_policy: plan.failure_policy,
              reduction_policy: plan.reduction_policy,
              retry_policy: plan.retry_policy,
              branch:
            }
          end

          def validate_plan_branch!(plan, branch)
            raise ArgumentError, "plan must be a Smith composite plan" unless plan.is_a?(Plan)
            raise ArgumentError, "branch must be a Smith composite branch" unless branch.is_a?(Branch)

            expected = plan.branches.fetch(branch.ordinal) do
              raise ArgumentError, "composite branch ordinal is invalid"
            end
            raise ArgumentError, "composite branch does not belong to plan" unless expected.to_h == branch.to_h
          end

          def normalize_dispatch!(attributes)
            value = attributes[:dispatch]
            attributes[:dispatch] = PreparedStepDispatch.deserialize(value) unless value.is_a?(PreparedStepDispatch)
          end

          def normalize_branch!(attributes)
            value = attributes[:branch]
            attributes[:branch] = Branch.deserialize(value) unless value.is_a?(Branch)
          end
        end

        def initialize(attributes)
          owned = self.class.normalize_attributes(attributes)
          super(owned)
          validate_contract!
        end

        private

        def validate_contract!
          Plan.validate_branch_count!(branch_count)
          raise ArgumentError, "composite branch ordinal exceeds branch count" if branch.ordinal >= branch_count
          unless execution_semantics_version == Smith::EXECUTION_SEMANTICS_VERSION
            raise ArgumentError, "composite branch execution semantics do not match"
          end

          expected = PayloadDigest.call(self.class.serializable(to_h.except(:digest)))
          raise ArgumentError, "composite branch execution digest does not match" unless digest == expected
        end
      end
    end
  end
end
