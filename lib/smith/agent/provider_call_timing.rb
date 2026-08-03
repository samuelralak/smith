# frozen_string_literal: true

module Smith
  class Agent
    # Monotonic timing and trace emission for one provider attempt: the
    # attempt's single measured duration wraps the whole chat completion
    # (including any provider-side tool loop). Per-network-round timing
    # belongs to the host's RubyLLM notification subscriptions, not Smith.
    module ProviderCallTiming
      class Timer
        def self.start
          new
        end

        def initialize
          @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @stopped_at = nil
        end

        # Idempotent: the first stop wins, so a rescue-path stop after a
        # success-path stop cannot stretch the measurement.
        def stop
          @stopped_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          self
        end

        def elapsed_ms
          ending = @stopped_at || Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ((ending - @started_at) * 1000).round
        end
      end

      private

      # One `:provider_call` trace per attempt: success, provider failure, or
      # aborted (a non-provider error that re-raises). Usage entries from the
      # same attempt share its attempt_id; join there instead of summing
      # durations across entries. duration_ms is present only when the timed
      # provider call actually started: a failure before dispatch (model
      # resolution, chat construction) emits its attempt without a duration.
      def record_provider_call_trace(attempt, attempt_index, aborted: false)
        Smith::Trace.record(
          type: :provider_call,
          data: {
            model: attempt.model_reference.model_id,
            provider: attempt.model_reference.provider,
            duration_ms: attempt.duration_ms,
            attempt_id: attempt.attempt_id,
            attempt_index: attempt_index,
            outcome: provider_call_outcome(attempt, aborted)
          }.compact
        )
      end

      def provider_call_outcome(attempt, aborted)
        return :aborted if aborted
        return :success if attempt.success?

        :failure
      end

      # Aborted (non-provider) attempts emit a :provider_call too, so the
      # prefix-accounted usage entries stamped with this attempt_id always
      # have their join target; the error then propagates unchanged.
      def failed_provider_attempt(error, observed_reference, attempt_id, timer, attempt_index)
        attempt = ProviderAttempt.failure(
          error: error, model_reference: observed_reference, attempt_id:, duration_ms: timer&.elapsed_ms
        )
        record_provider_call_trace(attempt, attempt_index, aborted: !provider_failure?(error))
        attempt
      end
    end
  end
end
