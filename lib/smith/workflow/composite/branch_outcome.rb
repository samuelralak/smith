# frozen_string_literal: true

require_relative "../../types"
require_relative "../message_value_normalizer"
require_relative "../prepared_step"
require_relative "effects"
require_relative "enums"
require_relative "error"
require_relative "payload"
require_relative "payload_digest"

module Smith
  class Workflow
    module Composite
      class BranchOutcome < Payload
        OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
        private_constant :OwnedString

        attribute :plan_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :branch_digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)
        attribute :ordinal, Types::Integer.constrained(gteq: 0, lteq: PreparedStep::MAX_COUNTER_VALUE)
        attribute :branch_key, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :agent, OwnedString.constrained(min_size: 1, max_size: 256)
        attribute :status, Types::Symbol.enum(:succeeded, :failed)
        attribute? :output, Types::Any.optional
        attribute? :error, Types.Instance(Error).optional
        attribute :effects, Types.Instance(Effects)
        attribute :digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)

        class << self
          def succeeded(plan_digest:, branch:, output:, effects:)
            build(plan_digest:, branch:, effects:, status: :succeeded, output:, error: nil)
          end

          def failed(plan_digest:, branch:, error:, effects:)
            build(plan_digest:, branch:, effects:, status: :failed, output: nil, error:)
          end

          def normalize_attributes(attributes)
            normalized = super
            normalize_status!(normalized)
            normalize_error!(normalized)
            normalize_effects!(normalized)
            normalized
          end

          private

          def build(plan_digest:, branch:, effects:, **result)
            values = {
              plan_digest:,
              branch_digest: branch.digest,
              ordinal: branch.ordinal,
              branch_key: branch.key,
              agent: branch.agent,
              status: result.fetch(:status),
              output: normalize_output(result.fetch(:output)),
              error: result.fetch(:error),
              effects:
            }
            new(values.merge(digest: PayloadDigest.call(serializable(values))))
          end

          def normalize_status!(attributes)
            attributes[:status] = Enums.normalize(:status, attributes[:status])
          end

          def normalize_error!(attributes)
            error = attributes[:error]
            attributes[:error] = Error.deserialize(error) if error && !error.is_a?(Error)
          end

          def normalize_effects!(attributes)
            effects = attributes[:effects]
            attributes[:effects] = Effects.deserialize(effects) unless effects.is_a?(Effects)
          end

          def normalize_output(value)
            MessageValueNormalizer.new(value, label: "composite branch output").call
          end

          def serializable(values)
            values.merge(error: values[:error]&.to_h, effects: values.fetch(:effects).to_h)
          end

          def legacy_serializable(values)
            serializable(values).tap do |payload|
              payload[:error] = payload[:error]&.except(:tool_name, :reason)
            end
          end
        end

        def initialize(attributes)
          owned = self.class.normalize_attributes(attributes)
          owned[:output] = self.class.send(:normalize_output, owned[:output])
          super(owned)
          validate_shape!
          validate_digest!
        end

        def succeeded? = status == :succeeded
        def failed? = status == :failed

        private

        def validate_digest!
          values = to_h.except(:digest)
          payloads = [self.class.send(:serializable, values)]
          payloads << self.class.send(:legacy_serializable, values) if legacy_digest_allowed?
          expected = payloads.map { PayloadDigest.call(_1) }
          raise ArgumentError, "composite branch outcome digest does not match" unless expected.include?(digest)
        end

        def legacy_digest_allowed?
          error.nil? || (error.tool_name.nil? && error.reason.nil?)
        end

        def validate_shape!
          valid = succeeded? ? error.nil? : error && output.nil?
          raise ArgumentError, "composite branch outcome fields do not match status" unless valid
        end
      end
    end
  end
end
