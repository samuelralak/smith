# frozen_string_literal: true

require "ruby_llm"

require_relative "tool/capability_builder"
require_relative "tool/policy"
require_relative "tool/call_allowance"
require_relative "tool/budget_enforcement"
require_relative "tool_capture_failed"
require_relative "tool/capture"
require_relative "tool/capture_configuration"
require_relative "tool/compatibility"
require_relative "tool/scoped_context"
require_relative "tool/chat_execution_context"

module Smith
  class Tool < RubyLLM::Tool
    include Policy
    include BudgetEnforcement
    include Capture
    extend CaptureConfiguration
    extend ScopedContext

    class << self
      # Tool subclasses inherit the parent's compatible_with spec by
      # reference (the spec is a frozen Hash; immutability makes shared
      # references safe). Subclasses can override by calling
      # `compatible_with` again — assigns a NEW frozen Hash to its own
      # @compatible_with_spec, leaving the parent untouched.
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@compatible_with_spec, @compatible_with_spec)
      end

      # Declarative compatibility DSL. Examples:
      #   compatible_with :anthropic, :gemini
      #   compatible_with :anthropic, :gemini, openai: :responses
      #   compatible_with except: { openai: :chat_completions }
      #
      # Tools that NEVER declare compatible_with are universally compatible.
      # Consumed by Smith::Models::Normalizer.drop_incompatible_tools when
      # the resolved model rejects the (tools + thinking) combo and no
      # routing fallback (e.g., openai_api_mode :auto) is available.
      def compatible_with(*providers, except: nil, **provider_endpoints)
        @compatible_with_spec = Compatibility.parse(providers, except: except, **provider_endpoints)
      end

      attr_reader :compatible_with_spec

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
      ensure_capture_ready!
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
