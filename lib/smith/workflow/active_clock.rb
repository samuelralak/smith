# frozen_string_literal: true

module Smith
  class Workflow
    # `wall_clock` bounds the time the run's steps spend running, not the
    # time since it was created: a run that waits for days, or whose host
    # advances it step by step from a queue, spends only its active time.
    # Each step's deadline is its start plus what is left of the budget, and
    # the step's monotonic duration is added to the persisted
    # `active_seconds` when it ends.
    module ActiveClock
      private

      def start_active_clock!
        @active_clock_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @active_clock_started_at = Time.now.utc
        remove_instance_variable(:@wall_clock_deadline) if defined?(@wall_clock_deadline)
      end

      def stop_active_clock!
        started = @active_clock_started
        return unless started

        @active_clock_started = nil
        @active_seconds = (@active_seconds || 0.0) + (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      end

      def active_deadline(limit)
        (@active_clock_started_at || Time.now.utc) + (limit - (@active_seconds || 0.0))
      end

      def restored_active_seconds(value)
        return 0.0 if value.nil?
        return value.to_f if (value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)) && !value.negative?

        raise Smith::SerializationError, "persisted workflow active_seconds must be a non-negative number"
      end
    end
  end
end
