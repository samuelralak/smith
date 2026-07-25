# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchSources
      extend Dry::Initializer

      param :entries

      def call
        bytes = 0
        metadata = entries.each_with_object([]) do |(key, tool_call), captured|
          source = ExecutionBatchSourceMetadata.capture(key:, tool_call:)
          bytes += source.metadata_byte_count
          validate_bytes!(bytes)
          captured << source
        end.freeze
        metadata.map(&:to_source_call).freeze
      end

      private

      def validate_bytes!(bytes)
        return if bytes <= ExecutionBatchSourceCall::MAX_METADATA_BYTES

        raise Error, "provider tool batch metadata exceeds #{ExecutionBatchSourceCall::MAX_METADATA_BYTES} bytes"
      end
    end
  end
end
