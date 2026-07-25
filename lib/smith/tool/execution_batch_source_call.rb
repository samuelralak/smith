# frozen_string_literal: true

require "dry-struct"

require_relative "../types"
require_relative "execution_batch_source_metadata"

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchSourceCall < Dry::Struct
      MAX_NAME_BYTES = ExecutionBatchSourceMetadata::MAX_NAME_BYTES
      MAX_METADATA_BYTES = ExecutionBatchSourceMetadata::MAX_METADATA_BYTES

      Name = Types.Instance(String) | Types.Instance(Symbol)
      private_constant :Name

      attribute :key, Types::Any
      attribute :tool_call, Types::Any
      attribute :tool_call_id, Types::String.optional
      attribute :name, Name
      attribute :canonical_name, Types::String.constrained(min_size: 1)
      attribute :arguments, Types::Any
      attribute :thought_signature, Types::String.optional
      attribute :metadata_byte_count, Types::Integer.constrained(gteq: 1)

      def self.capture(key:, tool_call:)
        ExecutionBatchSourceMetadata.capture(key:, tool_call:).to_source_call
      end

      def initialize(...)
        super
        freeze
      end
    end
  end
end
