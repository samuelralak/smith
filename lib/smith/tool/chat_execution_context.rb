# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ChatExecutionContext
      include BoundedCompletionInstallation
      include ExecutionFailureHandling
      include ExecutionDispatch
      include ChatExecutionCallbacks
      include ExecutionBatchLifecycle

      def self.install(chat)
        return chat unless chat.respond_to?(:tools) && chat.tools.respond_to?(:values)
        unless chat.respond_to?(:execute_tool, true)
          raise Error, "unsupported RubyLLM chat execution interface: missing #execute_tool"
        end

        chat.extend(self) unless chat.singleton_class < self
        chat.__send__(:smith_tool_execution_batches)
        chat
      end
    end
  end
end
