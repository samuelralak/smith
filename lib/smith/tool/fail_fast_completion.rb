# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module FailFastCompletion
      private

      def complete_with_fail_fast_policy(state, &)
        with_bounded_tool_call_preference(state.allowance.remaining, &)
      end

      def dispatch_fail_fast_calls(response, tool_calls, state)
        result = if concurrency
                   handle_concurrent_tool_calls(tool_calls)
                 else
                   handle_sequential_tool_calls(tool_calls)
                 end
        reset_tool_choice if forced_tool_choice?
        state.request_continuation! unless result
        result || response
      end
    end
  end
end
