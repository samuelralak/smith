# frozen_string_literal: true

require_relative "../../types"
require_relative "../message_value_normalizer"
require_relative "../prepared_step"
require_relative "payload"
require_relative "payload_digest"

module Smith
  class Workflow
    module Composite
      class Input < Payload
        OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
        private_constant :OwnedString

        attribute :agent_messages, Types::Any
        attribute :session_messages, Types::Array
        attribute :digest, OwnedString.constrained(format: PreparedStep::DIGEST_PATTERN)

        def self.build(agent_messages:, session_messages:)
          values = normalized_values(agent_messages:, session_messages:)
          new(values.merge(digest: PayloadDigest.call(values)))
        end

        def initialize(attributes)
          owned = self.class.normalize_attributes(attributes)
          values = self.class.send(
            :normalized_values,
            agent_messages: owned[:agent_messages],
            session_messages: owned[:session_messages]
          )
          super(values.merge(digest: owned[:digest]))
          raise ArgumentError, "composite input digest does not match" unless digest == PayloadDigest.call(values)
        end

        class << self
          private

          def normalized_values(agent_messages:, session_messages:)
            {
              agent_messages: normalize(agent_messages),
              session_messages: normalize(session_messages)
            }.freeze
          end

          def normalize(value)
            MessageValueNormalizer.new(value, label: "composite input").call
          end
        end
      end
    end
  end
end
