# frozen_string_literal: true

module Smith
  class Workflow
    # A step declared with `stream:` streams through its sink
    # (Smith::Streaming), which hears the step's outcome: the completed
    # step's output, a durable retry's wait, or the failure. Every other
    # step clears the stream, so none of its calls reach another step's
    # sink; a nested workflow is a run of its own, with its own steps.
    module StepStream
      private

      def with_step_stream(transition)
        @step_stream = transition.stream &&
                       Streaming.open(transition.stream, execution_key: @persistence_key, transition: transition.name)
        step = yield
        wait_pending?(step) ? @step_stream&.withdraw(:retry_wait) : @step_stream&.finish(step[:output])
        step
      rescue Exception => e # rubocop:disable Lint/RescueException -- the sink hears of every failure, then it goes on
        @step_stream&.fail(e.class)
        raise
      ensure
        @step_stream = nil
      end
    end
  end
end
