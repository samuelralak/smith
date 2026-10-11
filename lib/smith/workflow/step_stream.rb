# frozen_string_literal: true

module Smith
  class Workflow
    # A step declared with `stream:` streams through its sink
    # (Smith::Streaming), which hears the step's outcome: its accepted
    # output, a durable retry's wait, or its failure. Every other step clears
    # the stream, so none of its calls reach another step's sink; a nested
    # workflow is a run of its own, with its own steps.
    #
    # The accepted output reaches the sink once the step is stored: at once
    # for a run that is not stored (no persistence key), else when `persist!`
    # stores it, or when the run moves on without storing it. A store that
    # fails tells the sink the step failed, with the store's error.
    module StepStream
      private

      def with_step_stream(transition)
        @step_stream = transition.stream &&
                       Streaming.open(transition.stream, execution_key: @persistence_key, transition: transition.name)
        step = yield
        if wait_pending?(step) then @step_stream&.suspend
        elsif @step_stream then accept_streamed(@step_stream, step[:output])
        end
        step
      rescue Exception => e # rubocop:disable Lint/RescueException -- the sink hears of every failure, then it goes on
        @step_stream&.fail(e.class)
        raise
      ensure
        @step_stream = nil
      end

      def accept_streamed(session, output)
        return session.finish(output) unless @persistence_key

        @streamed_output = [session, output]
      end

      def deliver_streamed_output
        session, output = @streamed_output
        @streamed_output = nil
        session&.finish(output)
      end

      def discard_streamed_output(error_class)
        session, = @streamed_output
        @streamed_output = nil
        session&.fail(error_class)
      end
    end
  end
end
