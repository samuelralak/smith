# frozen_string_literal: true

require_relative "../diagnostic_text"

module Smith
  class Agent
    # Monotonic timing and trace emission for one provider attempt: the
    # attempt's single measured duration wraps the whole chat completion
    # (including any provider-side tool loop). Per-network-round timing
    # belongs to the host's RubyLLM notification subscriptions, not Smith.
    module ProviderCallTiming
      EXCEPTION_CAUSE = Exception.instance_method(:cause)
      private_constant :EXCEPTION_CAUSE

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
      # input_tokens and output_tokens total the attempt's usage entries, so
      # a host can record the whole attempt when it ends.
      def record_provider_call_trace(attempt, aborted: false)
        Smith::Trace.record(
          type: :provider_call,
          data: {
            model: attempt.model_reference.model_id,
            provider: attempt.model_reference.provider,
            duration_ms: attempt.duration_ms,
            attempt_id: attempt.attempt_id,
            attempt_index: attempt.attempt_index,
            outcome: provider_call_outcome(attempt, aborted),
            **provider_call_error_classes(attempt.error),
            agent_name: attempt.agent_name,
            **provider_call_usage(attempt.usage)
          }.compact
        )
      end

      # Token counts are metadata, never content, so the content policy
      # leaves them in place.
      def provider_call_usage(usage)
        return {} unless usage

        { input_tokens: usage.input_tokens, output_tokens: usage.output_tokens }
      end

      def provider_call_outcome(attempt, aborted)
        return :aborted if aborted
        return :success if attempt.success?

        :failure
      end

      # Class names only, never a message: the same bounded identifier the
      # failed :transition trace carries, for the error and its direct cause.
      def provider_call_error_classes(error)
        return {} unless error

        cause = provider_call_error_cause(error)
        {
          error_class: DiagnosticText.error_class_name(error),
          error_cause_class: cause && DiagnosticText.error_class_name(cause)
        }
      end

      # A transport error wraps what actually happened (never connected, or
      # lost the connection after sending); Faraday keeps it as
      # wrapped_exception when the error was not raised inside a rescue.
      def provider_call_error_cause(error)
        cause = EXCEPTION_CAUSE.bind_call(error)
        cause ||= error.wrapped_exception if error.respond_to?(:wrapped_exception)
        cause if cause.is_a?(Exception)
      rescue StandardError
        nil
      end

      def completed_provider_attempt(completion, observed_reference, timer, facts)
        attempt = ProviderAttempt.success(
          completion:, model_reference: observed_reference, duration_ms: timer.elapsed_ms,
          usage: ProviderUsage.sum(completion.provider_usages), **facts
        )
        record_provider_call_trace(attempt)
        attempt
      end

      # Aborted (non-provider) attempts emit a :provider_call too, so the
      # prefix-accounted usage entries stamped with this attempt_id always
      # have their join target; the error then propagates unchanged. A
      # provider failure's own reported usage is accounted beside the
      # completed prefix, so its trace totals both.
      def failed_provider_attempt(error, observed_reference, timer, facts, prefix_usages)
        aborted = !provider_failure?(error)
        usages = aborted ? prefix_usages : [*prefix_usages, ProviderUsage.from_message(error)].compact
        attempt = ProviderAttempt.failure(
          error:, model_reference: observed_reference, duration_ms: timer&.elapsed_ms,
          usage: ProviderUsage.sum(usages), **facts
        )
        record_provider_call_trace(attempt, aborted:)
        attempt
      end
    end
  end
end
