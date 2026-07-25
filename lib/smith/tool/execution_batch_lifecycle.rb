# frozen_string_literal: true

require "English"

module Smith
  class Tool < RubyLLM::Tool
    module ExecutionBatchLifecycle
      private

      def smith_tool_execution_batches = @smith_tool_execution_batches ||= ExecutionBatchRegistry.new

      def handle_sequential_tool_calls(tool_calls, ...)
        batch = execution_batch_context(tool_calls)
        admit_execution_batch(batch)
        super(batch.tool_calls, ...)
      rescue StandardError => e
        notify_unsettled_batch_failures(batch, e)
        raise
      ensure
        settle_execution_batch(batch, active_error: $ERROR_INFO)
      end

      def execute_tools_concurrently(tool_calls, ...)
        batch = execution_batch_context(tool_calls)
        admit_execution_batch(batch)
        super(batch.tool_calls, ...)
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise unless e.is_a?(StandardError)

        begin
          notify_unsettled_batch_failures(batch, e)
        rescue ToolFailureNotificationFailed => notification_failure
          record_batch_failure(batch, notification_failure)
        end
        raise(prioritized_batch_failure(batch) || e)
      ensure
        settle_execution_batch(batch, active_error: $ERROR_INFO)
      end

      def execution_batch_context(tool_calls)
        smith_tool_execution_batches.build_and_register(
          tool_calls:,
          tools:,
          context: Tool::ScopedContext.capture,
          admission_resolver: method(:smith_tool_call_admissions)
        )
      end

      def admit_execution_batch(batch)
        requests = batch.requests.values.freeze
        admitter = batch.context.fetch(:current_invocation_batch_admitter)
        return unless admitter && requests.any?

        Thread.handle_interrupt(Exception => :never) do
          admitter.call(requests:)
          batch.mark_host_admitted!
        end
      end

      def execution_batch(tool_call) = smith_tool_execution_batches.fetch(tool_call)

      def settle_execution_batch(batch, active_error:)
        return unless batch

        settlement_error = nil
        Thread.handle_interrupt(Exception => :never) do
          begin
            batch.settle!
          rescue Exception => e # rubocop:disable Lint/RescueException
            settlement_error = e
          end
        ensure
          smith_tool_execution_batches.unregister(batch)
        end
        return unless settlement_error
        raise settlement_error unless active_error

        log_preserved_settlement_failure(active_error, settlement_error)
      end

      def log_preserved_settlement_failure(active_error, settlement_error)
        Smith.config.logger&.error(
          "Smith tool batch settlement failed while preserving " \
          "#{active_error.class}: #{settlement_error.class}: #{settlement_error.message}"
        )
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end
    end
  end
end
