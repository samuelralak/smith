# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ExecutionDispatch
      private

      def execute_tool(tool_call)
        batch = execution_batch(tool_call)
        return super unless batch

        dispatch_call = batch.dispatch_for(tool_call)
        return execute_unmanaged_tool(batch, tool_call) { super } unless batch.request_for(dispatch_call)

        execute_managed_tool(batch, dispatch_call) { super(dispatch_call) }
      rescue Exception => e # rubocop:disable Lint/RescueException
        record_batch_failure(batch, e) if batch
        raise
      end

      def execute_managed_tool(batch, dispatch_call, &)
        current_tool = tools[dispatch_call.name.to_sym]
        claim = dispatch_claim(batch, dispatch_call)
        Tool::ScopedContext.around(dispatch_context(batch, dispatch_call, current_tool, claim)) do
          execute_admitted_tool(batch, dispatch_call, current_tool:, claim:, &)
        end
      end

      def dispatch_claim(batch, dispatch_call)
        Tool::ScopedContext.capture.fetch(:current_tool_dispatch_claim) || batch.claim_dispatch!(dispatch_call)
      end

      def dispatch_context(batch, dispatch_call, current_tool, claim)
        request = batch.request_for(dispatch_call)
        batch.context.merge(
          current_invocation: request.invocation,
          current_tool_dispatch_claim: claim,
          current_tool_dispatch_start_handler: dispatch_start_handler(batch, dispatch_call, current_tool, claim)
        ).freeze
      end

      def dispatch_start_handler(batch, dispatch_call, current_tool, claim)
        lambda do |executing_tool|
          batch.mark_started!(dispatch_call, claim:) if executing_tool.equal?(current_tool)
        end
      end

      def execute_unmanaged_tool(batch, tool_call)
        Tool::ScopedContext.around(batch.context) do
          mark_unmanaged_tool_dispatch_started!(tool_call)
          yield
        end
      end

      def execute_admitted_tool(batch, tool_call, current_tool:, claim:, &)
        batch.verify_dispatch!(tool_call, current_tool:, claim:)
        return yield if current_tool.__send__(:invocation_argument_error, tool_call.arguments)

        result = dispatch_with_admission(current_tool, claim, batch.admission_for(tool_call), &)
        batch.mark_executed!(tool_call, claim:)
        result
      end

      def dispatch_with_admission(tool, claim, admission, &block)
        ExecutionAuthority.around(tool:, dispatch_claim: claim) do
          admission ? CallAdmission.around(admission, &block) : block.call
        end
      end

      def mark_unmanaged_tool_dispatch_started!(tool_call)
        tool = tools[tool_call.name.to_sym]
        return unless tool.is_a?(RubyLLM::Tool) && !tool.is_a?(Smith::Tool)

        Tool.current_tool_execution_tracker&.mark_started!
      end
    end
  end
end
