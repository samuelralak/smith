# frozen_string_literal: true

module Smith
  module Streaming
    # One step execution's stream, from the step's start to its outcome.
    # Each provider call opens with `start(info)`, info being the step's
    # (the stream's name, the run's execution key, the transition) with the
    # step attempt (from 1), the model and its provider. `delta(text)` follows with each text
    # chunk of the reply (tool calls and thinking are not sent; a tool
    # loop's rounds are sent one after another). Before a call that
    # replaces the text sent, that text is withdrawn with `reset(reason)`:
    #
    #   :retry        the step is attempted again (`retry_on`)
    #   :fallback     another model answers (a provider failure, or a refusal)
    #   :truncation   the reply was cut off and is asked for again
    #   :repair       the reply could not be the output and is asked for again
    #   :retry_wait   the step waits out a durable retry's backoff
    #
    # The step then ends with `finish(output)`, the output it accepted
    # (after guardrails, the output contract and `output_to:`),
    # `fail(error_class)`, or `reset(:retry_wait)`, after which the attempt
    # that resumes it streams to a new sink. A sink that raises is logged
    # and the step goes on.
    class Session
      def initialize(sink, info)
        @sink = sink
        @info = info
        @open = false
        @settled = false
      end

      def start(attempt:, model:, provider:)
        return if @settled

        @open = true
        notify(:start, @info.merge(attempt:, model:, provider:).freeze)
      end

      def delta(text)
        notify(:delta, text) if @open && text.is_a?(String) && !text.empty?
      end

      # Withdraws the text sent since the last start, if any.
      def withdraw(reason)
        return unless @open

        @open = false
        notify(:reset, reason)
      end

      def finish(output) = settle(:finish, output)

      def fail(error_class) = settle(:fail, error_class)

      private

      def settle(method, value)
        return if @settled

        @settled = true
        @open = false
        notify(method, value)
      end

      def notify(method, value)
        @sink.public_send(method, value) if @sink.respond_to?(method)
      rescue StandardError => e
        Smith.config.logger&.error("Smith stream sink #{@info[:stream].inspect} #{method} error: #{e.class}")
      end
    end
  end
end
