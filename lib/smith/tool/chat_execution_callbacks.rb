# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ChatExecutionCallbacks
      private

      def execute_tool_with_callbacks(tool_call)
        batch = execution_batch(tool_call)
        dispatch_call = batch&.dispatch_for(tool_call)
        return super unless dispatch_call && batch.request_for(dispatch_call)

        execute_managed_tool_callbacks(batch, dispatch_call) do
          super(batch.source_for(dispatch_call))
        end
      end

      def execute_managed_tool_callbacks(batch, dispatch_call, &block)
        claim = batch.claim_dispatch!(dispatch_call)
        with_dispatch_claim(batch, claim) { complete_managed_callbacks(batch, dispatch_call, &block) }
      rescue StandardError => e
        handle_managed_callback_failure(batch, dispatch_call, claim, e)
      rescue Exception => e # rubocop:disable Lint/RescueException
        record_batch_failure(batch, e)
        raise
      end

      def with_dispatch_claim(batch, claim, &)
        context = batch.context.merge(current_tool_dispatch_claim: claim).freeze
        Tool::ScopedContext.around(context, &)
      end

      def complete_managed_callbacks(batch, dispatch_call)
        result = yield
        notify_rejected_callback_dispatch(batch, dispatch_call) unless batch.started?(dispatch_call)
        result
      end

      def handle_managed_callback_failure(batch, dispatch_call, claim, error)
        record_batch_failure(batch, error)
        raise error unless claim
        raise error if error.is_a?(ToolFailureNotificationFailed)

        failure = invocation_dispatch_failure(batch, dispatch_call, error)
        notify_invocation_failure(batch, dispatch_call, failure)
        raise failure
      end

      def notify_rejected_callback_dispatch(batch, dispatch_call)
        notify_invocation_failure(
          batch,
          dispatch_call,
          ToolDispatchRejected.new("tool invocation arguments were rejected before execution")
        )
      end
    end
  end
end
