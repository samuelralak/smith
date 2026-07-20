# frozen_string_literal: true

require_relative "../../types"
require_relative "../message_value_normalizer"
require_relative "../prepared_step"
require_relative "payload"
require_relative "payload_digest"

module Smith
  class Workflow
    module Composite
      class Branch < Payload
        MAX_BUDGET_DIMENSIONS = 128
        HASH_LENGTH = Hash.instance_method(:length)
        HASH_EACH_PAIR = Hash.instance_method(:each_pair)
        private_constant :HASH_LENGTH, :HASH_EACH_PAIR
        OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
        private_constant :OwnedString

        attribute :ordinal, Types::Integer.constrained(gteq: 0, lteq: PreparedStep::MAX_COUNTER_VALUE)
        attribute :key, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :agent, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :binding_identity, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :budget, Types::Hash
        attribute :digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)

        def self.build(ordinal:, key:, agent:, binding_identity:, budget:)
          attributes = {
            ordinal:,
            key: key.to_s,
            agent: agent.to_s,
            binding_identity:,
            budget: normalize_budget(budget)
          }
          new(attributes.merge(digest: PayloadDigest.call(attributes)))
        end

        def initialize(attributes)
          owned = self.class.normalize_attributes(attributes)
          owned[:budget] = self.class.send(:normalize_budget, owned[:budget])
          super(owned)
          expected = PayloadDigest.call(to_h.except(:digest))
          raise ArgumentError, "composite branch digest does not match" unless digest == expected
        end

        class << self
          private

          def normalize_budget(value)
            normalized = normalized_budget(value)
            validate_budget_dimensions!(normalized)
            copy_budget(normalized)
          end

          def normalized_budget(value)
            normalized = MessageValueNormalizer.new(value, label: "composite branch budget").call
            raise ArgumentError, "composite branch budget must be a Hash" unless normalized.is_a?(Hash)

            normalized
          end

          def validate_budget_dimensions!(budget)
            return if HASH_LENGTH.bind_call(budget) <= MAX_BUDGET_DIMENSIONS

            raise ArgumentError, "composite branch budget contains too many dimensions"
          end

          def copy_budget(normalized)
            budget = {}
            HASH_EACH_PAIR.bind_call(normalized) do |name, amount|
              validate_budget_dimension!(name)
              validate_budget_amount!(amount)
              budget[name.freeze] = amount
            end
            budget.freeze
          end

          def validate_budget_dimension!(name)
            return if name.length.between?(1, 256)

            raise ArgumentError, "composite branch budget dimensions must be bounded non-empty strings"
          end

          def validate_budget_amount!(amount)
            return if amount.is_a?(Numeric) && amount.finite? && amount >= 0

            raise ArgumentError, "composite branch budget values must be finite non-negative numbers"
          end
        end
      end
    end
  end
end
