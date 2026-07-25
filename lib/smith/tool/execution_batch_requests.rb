# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchRequests
      MAX_NODES = ArgumentSnapshot::MAX_NODES
      MAX_BYTES = ArgumentSnapshot::MAX_BYTES
      MAX_CALLS = ExecutionBatchCollection::MAX_CALLS

      extend Dry::Initializer

      option :targets
      option :invocations
      option :arguments

      def call
        raise Error, "tool batch exceeds #{MAX_CALLS} Smith tool calls" if targets.length > MAX_CALLS

        totals = [0, 0]
        targets.each_with_object({}.compare_by_identity) do |(tool_call, tool), requests|
          append_request!(requests, tool_call, tool, totals)
        end
          .freeze
      end

      private

      def validate_bounds!(node_count, byte_count)
        raise Error, "tool batch arguments exceed #{MAX_NODES} values" if node_count > MAX_NODES
        raise Error, "tool batch arguments exceed #{MAX_BYTES} bytes" if byte_count > MAX_BYTES
      end

      def append_request!(requests, tool_call, tool, totals)
        request = build_request(tool_call, tool)
        totals[0] += request.argument_node_count
        totals[1] += request.argument_byte_count
        validate_bounds!(*totals)
        requests[tool_call] = request
      end

      def build_request(tool_call, tool)
        InvocationRequest.new(
          invocation: invocations.fetch(tool_call),
          tool_class: tool.class,
          arguments: normalized_arguments(arguments.fetch(tool_call))
        )
      end

      def normalized_arguments(value)
        return {} if value.nil?
        return value if value.is_a?(Hash)

        raise Error, "tool call arguments must be an object"
      end
    end
  end
end
