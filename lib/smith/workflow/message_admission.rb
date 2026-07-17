# frozen_string_literal: true

require "digest"
require "dry-struct"
require "json"

require_relative "../errors"
require_relative "../types"
require_relative "message_value_normalizer"

module Smith
  class Workflow
    class MessageAdmission < Dry::Struct
      transform_keys(&:to_sym)
      schema schema.strict

      attribute :messages, Types::Array.of(Types::Hash)

      attr_reader :message_digest

      def initialize(attributes)
        normalized = MessageValueNormalizer.new(attributes.fetch(:messages)).call
        payload = JSON.generate(normalized, max_nesting: MessageValueNormalizer::MAX_DEPTH)
        if payload.bytesize > MessageValueNormalizer::MAX_BYTES
          raise WorkflowError,
                "session message batch exceeds maximum bytes #{MessageValueNormalizer::MAX_BYTES}"
        end

        super(messages: normalized)
        @message_digest = Digest::SHA256.hexdigest(payload).freeze
        self.attributes.freeze
        freeze
      rescue JSON::GeneratorError, JSON::NestingError => e
        raise WorkflowError, "session message batch is not canonical JSON: #{e.message}"
      end

      def message_count = messages.length
    end
  end
end
