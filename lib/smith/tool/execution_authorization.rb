# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ExecutionAuthorization
      private

      def authorize_tool_execution!
        claim = self.class.__send__(:current_tool_dispatch_claim)
        return unless claim
        return if ExecutionAuthority.current&.claim(self, claim)

        raise ToolExecutionNotAdmitted, "managed Smith tool execution requires its exact admitted dispatch authority"
      end
    end
  end
end
