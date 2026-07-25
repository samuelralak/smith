# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ExecutionLifecycle
      private

      def prepare_tool_execution!(kwargs)
        ensure_capture_ready!
        run_before_execute_hook!(kwargs)
        check_dispatch_deadline!
        check_privilege!(kwargs)
        check_authorization!(kwargs)
        run_tool_guardrails!(kwargs)
        check_dispatch_deadline!
        charge_tool_call!
        mark_tool_execution_started!
      end

      def perform_with_duration(kwargs)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = perform(**kwargs)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        [result, duration]
      end
    end
  end
end
