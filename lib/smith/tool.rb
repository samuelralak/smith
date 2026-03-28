# frozen_string_literal: true

require "ruby_llm"

require_relative "tool/capability_builder"
require_relative "tool/policy"
require_relative "tool/budget_enforcement"
require_relative "tool/capture"

module Smith
  class Tool < RubyLLM::Tool
    include Policy
    include BudgetEnforcement
    include Capture

    class << self
      def current_guardrails
        Thread.current[:smith_tool_guardrails]
      end

      def current_guardrails=(value)
        Thread.current[:smith_tool_guardrails] = value
      end

      def current_deadline
        Thread.current[:smith_tool_deadline]
      end

      def current_deadline=(value)
        Thread.current[:smith_tool_deadline] = value
      end

      def current_ledger
        Thread.current[:smith_tool_ledger]
      end

      def current_ledger=(value)
        Thread.current[:smith_tool_ledger] = value
      end

      def current_tool_call_allowance
        Thread.current[:smith_tool_call_allowance]
      end

      def current_tool_call_allowance=(value)
        Thread.current[:smith_tool_call_allowance] = value
      end

      def current_tool_result_collector
        Thread.current[:smith_tool_result_collector]
      end

      def current_tool_result_collector=(value)
        Thread.current[:smith_tool_result_collector] = value
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

      def capture_result(&block)
        return @capture_result unless block_given?

        @capture_result = block
      end
    end

    def execute(**kwargs)
      run_before_execute_hook!(kwargs)
      check_tool_deadline!
      check_privilege!(kwargs)
      check_authorization!(kwargs)
      run_tool_guardrails!(kwargs)
      check_tool_deadline!
      charge_tool_call!

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = perform(**kwargs)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      emit_tool_trace(kwargs, result, duration)
      capture_result_if_configured(kwargs, result)
      result
    end

    private

    def run_before_execute_hook!(kwargs)
      hook = self.class.before_execute
      return unless hook

      hook.call(self, kwargs)
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

    def check_tool_deadline!
      deadline = self.class.current_deadline
      return unless deadline

      raise DeadlineExceeded, "wall_clock deadline exceeded during tool execution" if Time.now.utc >= deadline
    end

    def perform(**kwargs)
      raise NotImplementedError, "#{self.class} must implement #perform"
    end
  end
end
