# frozen_string_literal: true

require "ruby_llm"

module Smith
  class Tool < RubyLLM::Tool
    class CapabilityBuilder
      def initialize
        @capabilities = {}
      end

      def sensitivity(value)  = @capabilities[:sensitivity] = value
      def privilege(value)    = @capabilities[:privilege] = value
      def network(value)      = @capabilities[:network] = value
      def approval(value)     = @capabilities[:approval] = value
      def data_volume(value)  = @capabilities[:data_volume] = value
      def to_h                = @capabilities
    end

    class << self
      def current_guardrails
        Thread.current[:smith_tool_guardrails]
      end

      def current_guardrails=(value)
        Thread.current[:smith_tool_guardrails] = value
      end

      def category(value = nil)
        return @category if value.nil?

        @category = value
      end

      def capabilities(&)
        return @capabilities unless block_given?

        builder = CapabilityBuilder.new
        builder.instance_eval(&)
        @capabilities = builder.to_h
      end

      def authorize(&block)
        return @authorize unless block_given?

        @authorize = block
      end

      def before_execute(&block)
        return @before_execute unless block_given?

        @before_execute = block
      end
    end

    def execute(**kwargs)
      run_before_execute_hook!(kwargs)
      check_authorization!(kwargs)
      run_tool_guardrails!(kwargs)

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = perform(**kwargs)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      emit_tool_trace(kwargs, result, duration)
      result
    end

    private

    def run_before_execute_hook!(kwargs)
      hook = self.class.before_execute
      return unless hook

      hook.call(self, kwargs)
    end

    def check_authorization!(kwargs)
      authorizer = self.class.authorize
      return unless authorizer

      context = kwargs[:context]
      raise ToolPolicyDenied unless authorizer.call(context)
    end

    def run_tool_guardrails!(kwargs)
      guardrails_classes = self.class.current_guardrails
      return unless guardrails_classes

      Array(guardrails_classes).each do |guardrails_class|
        Guardrails::Runner.run_tool(guardrails_class, name.to_sym, kwargs)
      end
    end

    def emit_tool_trace(kwargs, result, duration)
      Smith::Trace.record(
        type: :tool_call,
        data: { tool: name, args: kwargs, result: result, duration: duration },
        sensitivity: self.class.capabilities&.dig(:sensitivity) || :low
      )
    end

    def perform(**kwargs)
      raise NotImplementedError, "#{self.class} must implement #perform"
    end
  end
end
