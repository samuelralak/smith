# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ScopedContext
      CONTEXT_KEYS = {
        current_guardrails: :smith_tool_guardrails,
        current_deadline: :smith_tool_deadline,
        current_ledger: :smith_tool_ledger,
        current_tool_call_allowance: :smith_tool_call_allowance,
        current_tool_result_collector: :smith_tool_result_collector,
        current_invocation_context: :smith_tool_invocation_context
      }.freeze

      CONTEXT_KEYS.each do |reader, key|
        define_method(reader) { Thread.current[key] }
        define_method("#{reader}=") { |value| Thread.current[key] = value }
      end

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

      def with_invocation_context(value, &block)
        raise ArgumentError, "block required" unless block

        previous = current_invocation_context
        Thread.handle_interrupt(Object => :never) do
          self.current_invocation_context = value
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            self.current_invocation_context = previous
          end
        end
      end

      def self.install(values)
        CONTEXT_KEYS.each do |reader, key|
          Thread.current[key] = values.fetch(reader)
        end
      end
      private_class_method :install

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
