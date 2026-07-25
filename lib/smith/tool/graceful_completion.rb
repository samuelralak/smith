# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module GracefulCompletion
      private

      def complete_without_tools(state, &)
        unless state.begin_finalization == :started
          raise BoundedCompletionError, "tool-disabled budget finalization may run only once"
        end

        with_tools_disabled(&)
      rescue Exception # rubocop:disable Lint/RescueException
        state.abort_finalization!
        raise
      end
    end
  end
end
