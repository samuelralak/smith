# frozen_string_literal: true

require_relative "../../types"
require_relative "../../version"
require_relative "../prepared_step_dispatch"
require_relative "branch"
require_relative "enums"
require_relative "payload"
require_relative "payload_digest"
require_relative "plan_integrity"

module Smith
  class Workflow
    module Composite
      class Plan < Payload
        VERSION = 1
        MAX_BRANCHES = 10_000
        RESUME_POLICY = :incomplete_only
        FAILURE_POLICY = :host_committed_primary
        REDUCTION_POLICY = :ordered_all_success
        RETRY_POLICY = :none
        ENUM_ATTRIBUTES = %i[kind resume_policy failure_policy reduction_policy retry_policy].freeze
        private_constant :ENUM_ATTRIBUTES
        OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
        private_constant :OwnedString

        attribute :version, Types::Integer.enum(VERSION)
        attribute :execution_semantics_version, OwnedString.constrained(min_size: 1, max_size: 32)
        attribute :dispatch, Types.Instance(PreparedStepDispatch)
        attribute :kind, Types::Symbol.enum(:parallel, :fanout)
        attribute :transition, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :from, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :execution_namespace, OwnedString.constrained(format: PreparedStep::UUID_PATTERN)
        attribute :branches, Types::Array.of(Types.Instance(Branch))
        attribute :input_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :budget_state_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :resume_policy, Types::Symbol.enum(RESUME_POLICY)
        attribute :failure_policy, Types::Symbol.enum(FAILURE_POLICY)
        attribute :reduction_policy, Types::Symbol.enum(REDUCTION_POLICY)
        attribute :retry_policy, Types::Symbol.enum(RETRY_POLICY)
        attribute :plan_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)

        class << self
          def build(**attributes)
            values = {
              version: VERSION,
              execution_semantics_version: Smith::EXECUTION_SEMANTICS_VERSION,
              dispatch: attributes.fetch(:dispatch),
              kind: attributes.fetch(:kind),
              transition: attributes.fetch(:transition).to_s,
              from: attributes.fetch(:from).to_s,
              execution_namespace: attributes.fetch(:execution_namespace),
              branches: attributes.fetch(:branches),
              input_digest: attributes.fetch(:input_digest),
              budget_state_digest: attributes.fetch(:budget_state_digest),
              resume_policy: RESUME_POLICY,
              failure_policy: FAILURE_POLICY,
              reduction_policy: REDUCTION_POLICY,
              retry_policy: RETRY_POLICY
            }
            new(values.merge(plan_digest: PayloadDigest.call(serializable(values))))
          end

          def normalize_attributes(attributes)
            normalized = super
            normalize_dispatch!(normalized)
            normalize_branches!(normalized)
            normalize_policies!(normalized)
            normalized
          end

          def preflight_attributes!(attributes)
            branches = raw_attribute(attributes, :branches)
            validate_branch_count!(branches) if branches.is_a?(Array)
            attributes
          end

          def serializable(values)
            values.merge(
              dispatch: values.fetch(:dispatch).to_h,
              branches: values.fetch(:branches).map(&:to_h)
            )
          end

          def validate_branch_count!(branches_or_count)
            count = if branches_or_count.is_a?(Array)
                      Array.instance_method(:length).bind_call(branches_or_count)
                    else
                      branches_or_count
                    end
            return if count&.between?(1, MAX_BRANCHES)

            raise ArgumentError, "composite plan branch count is outside the transport limit"
          end

          private

          def normalize_dispatch!(attributes)
            dispatch = attributes[:dispatch]
            attributes[:dispatch] = PreparedStepDispatch.deserialize(dispatch) unless
              dispatch.is_a?(PreparedStepDispatch)
          end

          def normalize_branches!(attributes)
            branches = attributes[:branches]
            validate_branch_count!(branches)
            normalized = []
            Array.instance_method(:each).bind_call(branches) do |branch|
              normalized << (branch.is_a?(Branch) ? branch : Branch.deserialize(branch))
            end
            attributes[:branches] = normalized.freeze
          end

          def normalize_policies!(attributes)
            ENUM_ATTRIBUTES.each { |key| attributes[key] = Enums.normalize(key, attributes[key]) }
          end
        end

        def initialize(attributes)
          self.class.preflight_attributes!(attributes)
          owned = self.class.normalize_attributes(attributes)
          super(owned)
          PlanIntegrity.new(self).call
        end

        def execution_for(branch) = BranchExecution.build(plan: self, branch:)
      end
    end
  end
end
