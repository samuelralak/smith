# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchBuilder
      def initialize
        @default_sequence = InvocationSequence.new
        @invocations = ExecutionBatchInvocations.new
      end

      def call(entries:, tools:, context:, call_admissions:)
        sources = ExecutionBatchSources.new(entries).call
        sources_by_call = index_sources(sources)
        source_targets = build_targets(sources, tools)
        source_requests = build_requests(source_targets, sources_by_call, context)
        dispatch_calls = build_dispatch_calls(source_requests, sources_by_call)
        attributes = batch_attributes(sources, source_targets, source_requests, dispatch_calls, context)
        inherited = call_admissions && remap(call_admissions, dispatch_calls)
        build_batch(attributes, inherited)
      end

      private

      def build_requests(targets, sources_by_call, context)
        sequence = context.fetch(:current_invocation_sequence) || @default_sequence
        target_sources = targets.each_key.map { sources_by_call.fetch(_1) }
        invocations = @invocations.call(sources: target_sources, sequence:)
        arguments = target_sources.each_with_object({}.compare_by_identity) do |source, indexed|
          indexed[source.tool_call] = source.arguments
        end.freeze
        ExecutionBatchRequests.new(targets:, invocations:, arguments:).call
      end

      def batch_attributes(sources, targets, requests, dispatch_calls, context)
        {
          context:,
          tool_calls: build_tool_calls(sources, dispatch_calls),
          source_calls: sources.map(&:tool_call).freeze,
          dispatch_calls:,
          source_calls_by_dispatch: invert(dispatch_calls),
          requests: remap(requests, dispatch_calls),
          targets: remap(targets, dispatch_calls)
        }
      end

      def build_batch(attributes, inherited_admissions)
        tool_calls = attributes.fetch(:tool_calls)
        reservation = ExecutionBatchAdmission.new(
          calls: tool_calls.values.freeze,
          context: attributes.fetch(:context)
        ).call
        ExecutionBatch.new(
          **attributes,
          call_reservation: reservation,
          call_admissions: build_call_admissions(attributes.fetch(:targets), reservation, inherited_admissions)
        )
      rescue Exception # rubocop:disable Lint/RescueException
        reservation&.settle!
        raise
      end

      def build_dispatch_calls(requests, sources_by_call)
        requests.each_with_object({}.compare_by_identity) do |(source_call, request), dispatch_calls|
          invocation = request.invocation
          source = sources_by_call.fetch(source_call)
          dispatch_calls[source_call] = RubyLLM::ToolCall.new(
            id: invocation.tool_call_id,
            name: source.name,
            arguments: request.arguments,
            thought_signature: source.thought_signature
          )
        end.freeze
      end

      def build_tool_calls(sources, dispatch_calls)
        sources.to_h { |source| [source.key, dispatch_calls.fetch(source.tool_call, source.tool_call)] }.freeze
      end

      def remap(source_values, dispatch_calls)
        source_values.each_with_object({}.compare_by_identity) do |(source_call, value), mapped|
          mapped[dispatch_calls.fetch(source_call)] = value
        end.freeze
      end

      def invert(source)
        source.each_with_object({}.compare_by_identity) do |(key, value), inverted|
          inverted[value] = key
        end.freeze
      end

      def index_sources(sources)
        sources.each_with_object({}.compare_by_identity) { |source, indexed| indexed[source.tool_call] = source }.freeze
      end

      def build_targets(sources, tools)
        sources.each_with_object({}.compare_by_identity) do |source, targets|
          tool = tools[source.name.to_sym]
          targets[source.tool_call] = tool if tool.is_a?(Smith::Tool)
        end.freeze
      end

      def build_call_admissions(targets, reservation, inherited)
        if reservation
          raise Error, "tool call has overlapping admission owners" if inherited&.any?

          return targets.each_with_object({}.compare_by_identity) do |(tool_call, tool), admissions|
            admissions[tool_call] = CallAdmission.new(tool:, reservation:)
          end.freeze
        end
        return {}.compare_by_identity.freeze unless inherited

        validate_inherited_admissions!(targets, inherited)
        inherited
      end

      def validate_inherited_admissions!(targets, inherited)
        complete = targets.length == inherited.length && targets.each_key.all? { inherited.key?(_1) }
        raise Error, "inherited tool admissions do not cover the immutable Smith batch" unless complete
      end
    end
  end
end
