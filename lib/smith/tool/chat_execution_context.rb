# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ChatExecutionContext
      def self.install(chat)
        return chat unless chat.respond_to?(:tools) && chat.tools.respond_to?(:values)
        unless chat.respond_to?(:execute_tool, true)
          raise Error, "unsupported RubyLLM chat execution interface: missing #execute_tool"
        end

        chat.extend(self) unless chat.singleton_class < self
        chat.__send__(:install_smith_tool_execution_context)
        chat
      end

      private

      def install_smith_tool_execution_context
        return if defined?(@smith_tool_execution_batches_mutex)

        @smith_tool_execution_batches = {}.compare_by_identity
        @smith_tool_execution_batches_mutex = Mutex.new
      end

      def execute_tool(tool_call)
        batch = execution_batch(tool_call)
        return super unless batch

        Tool::ScopedContext.around(batch.fetch(:context)) { super }
      rescue Exception => e # rubocop:disable Lint/RescueException
        record_batch_failure(batch, e) if batch
        raise
      end

      def execute_tools_concurrently(tool_calls, ...)
        batch = execution_batch_context
        register_execution_batch(tool_calls, batch)
        super
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise e unless e.is_a?(StandardError)

        fatal_failure = first_failure(batch&.fetch(:fatal_failures))
        raise fatal_failure if fatal_failure

        capture_failure = first_failure(batch&.fetch(:capture_failures))
        raise capture_failure if capture_failure

        raise
      ensure
        unregister_execution_batch(tool_calls, batch)
      end

      def execution_batch_context
        {
          context: Tool::ScopedContext.capture,
          capture_failures: Queue.new,
          fatal_failures: Queue.new
        }.freeze
      end

      def register_execution_batch(tool_calls, batch)
        @smith_tool_execution_batches_mutex.synchronize do
          tool_calls.each_value do |tool_call|
            raise Error, "tool call is already active on this chat" if @smith_tool_execution_batches.key?(tool_call)

            @smith_tool_execution_batches[tool_call] = batch
          end
        end
      end

      def unregister_execution_batch(tool_calls, batch)
        return unless tool_calls && batch

        @smith_tool_execution_batches_mutex.synchronize do
          tool_calls.each_value do |tool_call|
            @smith_tool_execution_batches.delete(tool_call) if @smith_tool_execution_batches[tool_call].equal?(batch)
          end
        end
      end

      def execution_batch(tool_call)
        @smith_tool_execution_batches_mutex.synchronize do
          @smith_tool_execution_batches[tool_call]
        end
      end

      def record_batch_failure(batch, error)
        if error.is_a?(ToolCaptureFailed)
          batch.fetch(:capture_failures).push(error)
        elsif !error.is_a?(StandardError)
          batch.fetch(:fatal_failures).push(error)
        end
      end

      def first_failure(queue)
        return unless queue

        queue.pop(true)
      rescue ThreadError
        nil
      end
    end
  end
end
