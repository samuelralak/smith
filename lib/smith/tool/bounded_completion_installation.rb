# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module BoundedCompletionInstallation
      def complete(&)
        allowance = Tool.current_tool_call_allowance
        return super unless allowance.is_a?(CallAllowance)
        return super if singleton_class < BoundedCompletionContext

        BoundedCompletionContext.install(self)
        complete(&)
      end

      private

      def smith_tool_call_admissions(_tool_calls) = nil
    end
  end
end
