# frozen_string_literal: true

require "dry-initializer"

require_relative "../errors"
require_relative "message_admission"

module Smith
  class Workflow
    class MessageBatch
      MAX_MESSAGES = 100
      MAX_DEPTH = MessageValueNormalizer::MAX_DEPTH
      MAX_NODES = MessageValueNormalizer::MAX_NODES
      MAX_BYTES = MessageValueNormalizer::MAX_BYTES
      ARRAY_EACH = Array.instance_method(:each)
      private_constant :ARRAY_EACH

      extend Dry::Initializer

      param :messages

      def call
        batch = normalize_batch
        batch.each { reject!("each session message must be a Hash") unless _1.is_a?(Hash) }
        admission = MessageAdmission.new(messages: batch)
        admission.messages.each { validate_message!(_1) }
        admission
      end

      private

      def normalize_batch
        return [messages] if messages.is_a?(Hash)

        reject!("session messages must be a message Hash or an Array of message Hashes") unless messages.is_a?(Array)

        batch = []
        ARRAY_EACH.bind_call(messages) do |message|
          reject!("session message batch exceeds maximum count #{MAX_MESSAGES}") if batch.length == MAX_MESSAGES

          batch << message
        end
        reject!("session message batch must not be empty") if batch.empty?

        batch
      end

      def validate_message!(message)
        reject!("each session message must be a Hash") unless message.is_a?(Hash)
        role = message["role"]
        reject!("each session message requires a non-empty role") unless
          role.is_a?(String) && !role.strip.empty?
      end

      def reject!(message)
        raise WorkflowError, message
      end
    end
  end
end
