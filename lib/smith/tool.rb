# frozen_string_literal: true

require "ruby_llm"

require_relative "tool/capability_builder"
require_relative "tool/policy"
require_relative "tool/call_budget"
require_relative "tool/call_batch"
require_relative "tool/legacy_call_allowance"
require_relative "tool/call_allowance_counter"
require_relative "tool/call_allowance"
require_relative "tool/call_reservation"
require_relative "tool/call_admission"
require_relative "tool/execution_authority"
require_relative "tool/execution_authorization"
require_relative "tool/execution_tracker"
require_relative "tool/execution_lifecycle"
require_relative "tool/invocation"
require_relative "tool/argument_snapshot_result"
require_relative "tool/argument_scalar_snapshot"
require_relative "tool/argument_container_reader"
require_relative "tool/argument_snapshot_accounting"
require_relative "tool/argument_snapshot_traversal"
require_relative "tool/argument_snapshot"
require_relative "tool/invocation_request"
require_relative "tool/invocation_sequence"
require_relative "tool/execution_batch_collection"
require_relative "tool/execution_batch_invocations"
require_relative "tool/execution_batch_source_metadata"
require_relative "tool/execution_batch_source_call"
require_relative "tool/execution_batch_sources"
require_relative "tool/execution_batch_state"
require_relative "tool/execution_batch"
require_relative "tool/execution_batch_admission"
require_relative "tool/execution_batch_requests"
require_relative "tool/execution_batch_builder"
require_relative "tool/execution_batch_registry"
require_relative "tool/budget_enforcement"
require_relative "tool_capture_failed"
require_relative "tool/capture"
require_relative "tool/capture_configuration"
require_relative "tool/compatibility"
require_relative "tool/scoped_context"
require_relative "tool/bounded_completion_state"
require_relative "tool/bounded_completion_guard"
require_relative "tool/bounded_completion_controls"
require_relative "tool/fail_fast_completion"
require_relative "tool/graceful_completion"
require_relative "tool/bounded_completion_context"
require_relative "tool/bounded_completion_installation"
require_relative "tool/execution_failure_handling"
require_relative "tool/execution_dispatch"
require_relative "tool/chat_execution_callbacks"
require_relative "tool/execution_batch_lifecycle"
require_relative "tool/chat_execution_context"

module Smith
  class Tool < RubyLLM::Tool
    include Policy
    include ExecutionAuthorization
    include ExecutionLifecycle
    include BudgetEnforcement
    include Capture
    extend CaptureConfiguration
    extend ScopedContext

    private_constant :ExecutionAuthority

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
      authorize_tool_execution!
      kwargs.freeze
      prepare_tool_execution!(kwargs)
      result, duration = perform_with_duration(kwargs)

      emit_tool_trace(kwargs, result, duration)
      capture_result_if_configured(kwargs, result)
      result
    end

    protected

    def invocation_argument_error(arguments) = validate_keyword_arguments(normalize_args(arguments))

    def execute_keyword_signature
      parameters = method(:perform).parameters
      required_keywords = parameters.filter_map { |kind, name| name if kind == :keyreq }
      optional_keywords = parameters.filter_map { |kind, name| name if kind == :key }
      accepts_extra_keywords = parameters.any? { |kind, _| kind == :keyrest }
      accepts_positional_arguments = parameters.any? do |kind, _|
        RubyLLM::Tool::POSITIONAL_PARAMETER_KINDS.include?(kind)
      end

      [required_keywords, optional_keywords, accepts_extra_keywords, accepts_positional_arguments]
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
      # tool_call_id is the provider's correlation id for this invocation
      # (present only when the call came from a provider batch); it lets a
      # host join this trace to its own per-invocation records.
      Smith::Trace.record(
        type: :tool_call,
        data: {
          tool: name,
          args: kwargs,
          result: result,
          duration: duration,
          tool_call_id: self.class.current_invocation&.tool_call_id
        }.compact,
        sensitivity: self.class.capabilities&.dig(:sensitivity) || :low
      )
    end

    def check_tool_deadline!
      deadline = self.class.current_deadline
      return unless deadline

      raise DeadlineExceeded, "wall_clock deadline exceeded during tool execution" if Time.now.utc >= deadline
    end

    def check_dispatch_deadline!
      check_tool_deadline!
    rescue DeadlineExceeded
      raise ToolDispatchRejected, "tool deadline expired before dispatch"
    end

    def perform(**kwargs)
      raise NotImplementedError, "#{self.class} must implement #perform"
    end
  end
end
