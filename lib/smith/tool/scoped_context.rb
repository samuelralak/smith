# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ScopedContext
      CONTEXT_KEYS = {
        current_guardrails: :smith_tool_guardrails,
        current_deadline: :smith_tool_deadline,
        current_ledger: :smith_tool_ledger,
        current_tool_call_allowance: :smith_tool_call_allowance,
        current_tool_execution_tracker: :smith_tool_execution_tracker,
        current_tool_dispatch_claim: :smith_tool_dispatch_claim,
        current_tool_dispatch_start_handler: :smith_tool_dispatch_start_handler,
        current_tool_result_collector: :smith_tool_result_collector,
        current_invocation_context: :smith_tool_invocation_context,
        current_invocation_batch_admitter: :smith_tool_invocation_batch_admitter,
        current_invocation_failure_handler: :smith_tool_invocation_failure_handler,
        current_invocation_sequence: :smith_tool_invocation_sequence,
        current_invocation: :smith_tool_invocation
      }.freeze

      CONTEXT_KEYS.each do |reader, key|
        define_method(reader) { Thread.current[key] }
        define_method("#{reader}=") { |value| Thread.current[key] = value }
      end

      private :current_invocation_batch_admitter,
              :current_invocation_batch_admitter=,
              :current_invocation_failure_handler,
              :current_invocation_failure_handler=,
              :current_invocation_sequence,
              :current_invocation_sequence=,
              :current_tool_dispatch_claim,
              :current_tool_dispatch_claim=,
              :current_tool_dispatch_start_handler,
              :current_tool_dispatch_start_handler=,
              :current_invocation=

      def self.capture
        CONTEXT_KEYS.to_h { |reader, key| [reader, Thread.current[key]] }.freeze
      end

      def self.around(values, &block)
        raise ArgumentError, "block required" unless block

        validate!(values)
        previous = capture
        Thread.handle_interrupt(Object => :never) do
          install(values)
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            install(previous)
          end
        end
      end

      def with_invocation_context(value, invocation_sequence: InvocationSequence.new, batch_admitter: nil,
                                  failure_handler: nil, &block)
        raise ArgumentError, "block required" unless block
        unless invocation_sequence.is_a?(InvocationSequence)
          raise ArgumentError, "invocation sequence must be a Smith::Tool::InvocationSequence"
        end

        validate_callback!(batch_admitter, "batch admitter")
        validate_callback!(failure_handler, "failure handler")
        if batch_admitter && !failure_handler
          raise ArgumentError, "invocation failure handler is required when a batch admitter is configured"
        end

        values = ScopedContext.capture.merge(
          current_invocation_context: value,
          current_invocation_batch_admitter: batch_admitter,
          current_invocation_failure_handler: failure_handler,
          current_invocation_sequence: invocation_sequence,
          current_invocation: nil
        ).freeze
        ScopedContext.around(values, &block)
      end

      def with_call_budget(budget, on_exhaustion: :raise, &block)
        raise ArgumentError, "block required" unless block

        previous = current_tool_call_allowance
        if previous && !previous.is_a?(CallAllowance)
          raise ArgumentError, "a scoped tool call budget cannot nest under a legacy Hash tool call allowance"
        end

        allowance = previous ? previous.scope(budget, on_exhaustion:) : CallAllowance.new(budget, on_exhaustion:)
        Thread.handle_interrupt(Object => :never) do
          self.current_tool_call_allowance = allowance
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            self.current_tool_call_allowance = previous
          end
        end
      end

      def self.install(values)
        CONTEXT_KEYS.each { |reader, key| Thread.current[key] = values.fetch(reader) }
      end
      private_class_method :install

      def validate_callback!(callback, name)
        return if callback.nil? || callback.respond_to?(:call)

        raise ArgumentError, "invocation #{name} must respond to #call"
      end
      private :validate_callback!

      def self.validate!(values)
        complete = values.is_a?(Hash) && values.length == CONTEXT_KEYS.length && CONTEXT_KEYS.each_key.all? do |key|
          values.key?(key)
        end
        return if complete

        raise ArgumentError, "tool context must contain the complete scoped context"
      end
      private_class_method :validate!
    end
  end
end
