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
        pass_interruption!(batch, e)
        raise ToolFailureNotificationFailed.new(
          dispatch_error: error,
          notification_error: e
        ), cause: e
      end

      # An interruption settles nothing, as a process that died settles
      # nothing: the host reconciles the batch's unsettled requests, whichever
      # of its calls' errors reached here first.
      def notify_unsettled_batch_failures(batch, error)
        return unless batch&.host_admitted?
        return if Interruptions.find(error) || batch.interrupted?

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
            pass_interruption!(batch, e)
            first_error ||= ToolFailureNotificationFailed.new(
              dispatch_error: failure,
              notification_error: e
            )
          end
        end
        first_error
      end

      # A failure handler that met an interruption stops the batch with it, as
      # it was raised; what it had not settled stays unsettled for the host.
      def pass_interruption!(batch, error)
        return unless Interruptions.find(error)

        record_batch_failure(batch, error)
        Interruptions.pass!(error)
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
        interrupted = Interruptions.find(error)
        batch.interrupted! if interrupted
        batch_failure_queue(batch, error, interrupted)&.push(error)
      end

      # An interruption counts as process-fatal: nothing else is raised over it.
      def batch_failure_queue(batch, error, interrupted)
        return batch.fatal_failures if interrupted || !error.is_a?(StandardError)
        return batch.notification_failures if error.is_a?(ToolFailureNotificationFailed)
        return batch.capture_failures if error.is_a?(ToolCaptureFailed)

        batch.terminal_failures if Smith::Errors.retry_forbidden?(error)
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
