# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module ExecutionFailureHandling
      private

      def notify_invocation_failure(batch, tool_call, error)
        return unless batch&.host_admitted?

        entry = batch&.claim_failure_request(tool_call)
        return unless entry

        request, state = entry
        batch.context.fetch(:current_invocation_failure_handler)&.call(request:, error:)
        batch.complete_failure_notification!(tool_call)
      rescue StandardError => e
        batch.release_failure_notification!(tool_call, state)
        raise ToolFailureNotificationFailed.new(
          dispatch_error: error,
          notification_error: e
        ), cause: e
      end

      def notify_unsettled_batch_failures(batch, error)
        return unless batch&.host_admitted?

        handler = batch.context.fetch(:current_invocation_failure_handler)
        handler_error = notify_unsettled_requests(batch, error, handler)
        raise handler_error if handler_error
      end

      def notify_unsettled_requests(batch, error, handler)
        first_error = nil
        while (entry = batch.claim_unsettled_request)
          tool_call, request, state = entry
          failure = batch_dispatch_failure(error, state)
          begin
            handler&.call(request:, error: failure)
            batch.complete_failure_notification!(tool_call)
          rescue StandardError => e
            batch.release_failure_notification!(tool_call, state)
            first_error ||= ToolFailureNotificationFailed.new(
              dispatch_error: failure,
              notification_error: e
            )
          end
        end
        first_error
      end

      def batch_dispatch_failure(error, state)
        return error.dispatch_error if error.is_a?(ToolFailureNotificationFailed)
        return error if state == :started || exact_dispatch_failure?(error)

        ToolDispatchRejected.new("tool batch dispatch failed before execution")
      end

      def invocation_dispatch_failure(batch, tool_call, error)
        return error if exact_dispatch_failure?(error) || batch&.started?(tool_call)
        return error unless batch&.host_admitted?

        ToolDispatchRejected.new("tool invocation failed before execution")
      end

      def exact_dispatch_failure?(error)
        error.is_a?(ToolDispatchRejected) || error.is_a?(ToolExecutionNotAdmitted)
      end

      def record_batch_failure(batch, error)
        if !error.is_a?(StandardError)
          batch.fatal_failures.push(error)
        elsif error.is_a?(ToolFailureNotificationFailed)
          batch.notification_failures.push(error)
        elsif error.is_a?(ToolCaptureFailed)
          batch.capture_failures.push(error)
        elsif Smith::Errors.retry_forbidden?(error)
          batch.terminal_failures.push(error)
        end
      end

      def prioritized_batch_failure(batch)
        return unless batch

        %i[fatal_failures notification_failures capture_failures terminal_failures].each do |queue|
          failure = first_failure(batch.public_send(queue))
          return failure if failure
        end
        nil
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
