# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module BoundedCompletionContext
      include BoundedCompletionControls
      include FailFastCompletion
      include GracefulCompletion

      SUPPORTED_RUBY_LLM = Gem::Requirement.new("= 1.16.0")
      REQUIRED_HOOKS = %i[
        add_tool_result_message forced_tool_choice? handle_concurrent_tool_calls handle_sequential_tool_calls
        params reset_tool_choice run_callbacks
      ].freeze

      private_constant :SUPPORTED_RUBY_LLM, :REQUIRED_HOOKS

      def self.install(chat)
        version = Gem::Version.new(RubyLLM::VERSION)
        raise Error, "bounded completion requires RubyLLM 1.16.0" unless SUPPORTED_RUBY_LLM.satisfied_by?(version)

        missing = REQUIRED_HOOKS.reject { |hook| chat.respond_to?(hook, true) }
        valid = missing.empty? && chat.respond_to?(:tool_prefs) && chat.tool_prefs.respond_to?(:replace)
        raise Error, "unsupported RubyLLM tool-loop interface for bounded completion" unless valid

        chat.extend(self) unless chat.singleton_class < self
        chat.__send__(:install_bounded_completion_context)
        chat
      end

      def complete(&stream)
        allowance = Tool.current_tool_call_allowance
        owner = [Thread.current, Fiber.current]
        iterative = allowance.is_a?(CallAllowance)

        bounded_completion_guard.around_completion(owner, reentrant: !iterative) do
          return super(&stream) unless iterative

          validate_reserved_params!
          validate_supported_tools! if allowance.complete_on_exhaustion?
          state = bounded_completion_guard.state_for(allowance)
          loop do
            result = complete_with_budget_policy(state) { super(&stream) }
            return result unless state.consume_continuation!
          end
        end
      end

      private

      def install_bounded_completion_context
        return if @smith_bounded_completion_guard

        @smith_bounded_completion_guard = BoundedCompletionGuard.new
      end

      def complete_with_budget_policy(state, &completion)
        return complete_with_fail_fast_policy(state, &completion) unless state.allowance.complete_on_exhaustion?

        if state.finalization_required? || state.allowance.remaining.zero?
          complete_without_tools(state, &completion)
        else
          with_bounded_tool_call_preference(state.allowance.remaining) do
            with_sequential_tool_execution(&completion)
          end
        end
      end

      def handle_tool_calls(response, &)
        state = current_bounded_completion_state
        return super unless state

        tool_calls = validated_tool_calls(response)
        return dispatch_fail_fast_calls(response, tool_calls, state) unless state.allowance.complete_on_exhaustion?
        return reject_finalization_violation(tool_calls, state) if state.finalization_started?

        admitted, result = dispatch_admitted_calls(response, tool_calls, state)
        return result if admitted

        complete_rejected_batch(response, tool_calls, state)
      end

      def execute_tool(tool_call)
        admission = bounded_completion_guard.admission_for(tool_call)
        return super unless admission

        CallAdmission.around(admission) { super }
      end

      def current_bounded_completion_state
        allowance = Tool.current_tool_call_allowance
        return unless allowance.is_a?(CallAllowance)

        bounded_completion_guard.state_for(allowance)
      end

      def dispatch_admitted_calls(response, tool_calls, state)
        result = nil
        admitted = bounded_completion_guard.with_admitted_calls(
          tool_calls,
          tools:,
          allowance: state.allowance,
          ledger: Tool.current_ledger
        ) do
          result = handle_sequential_tool_calls(tool_calls)
        end
        return [false, nil] unless admitted

        reset_tool_choice if forced_tool_choice?
        state.request_continuation! unless result
        [true, result || response]
      end

      def complete_rejected_batch(response, tool_calls, state)
        state.request_finalization!
        append_budget_rejections(tool_calls, state.allowance)
        reset_tool_choice if forced_tool_choice?
        state.request_continuation!
        response
      end

      def bounded_completion_guard
        @smith_bounded_completion_guard || raise(Error, "bounded completion context is not installed")
      end

      def smith_tool_call_admissions(tool_calls)
        bounded_completion_guard.admissions_for(tool_calls)
      end
    end
  end
end
