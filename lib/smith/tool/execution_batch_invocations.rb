# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchInvocations
      def call(sources:, sequence:)
        return {}.compare_by_identity.freeze if sources.empty?

        first_ordinal = sequence.reserve(sources.length)
        sources.each_with_index.with_object({}.compare_by_identity) do |(source, index), invocations|
          invocations[source.tool_call] = build_invocation(source, index, first_ordinal, sources.length)
        end.freeze
      end

      private

      def build_invocation(source, index, first_ordinal, batch_size)
        Invocation.new(
          tool_call_id: source.tool_call_id,
          tool_name: source.canonical_name,
          ordinal: first_ordinal + index,
          batch_ordinal: index + 1,
          batch_size:
        )
      end
    end
  end
end
