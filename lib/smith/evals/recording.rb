# frozen_string_literal: true

module Smith
  module Evals
    # Experimental. The observer `require "smith/evals"` installs into
    # Smith's attempt seam (Smith::AttemptObservation; slice-1a design, 5.4):
    # it hands each provider attempt observed under a trial (Smith::Evals.under
    # routes by the trial id) to the recorder attached for that trial, and
    # drops one for a trial with none attached (a stray thread after its
    # trial ended). The runner attaches a fresh Recorder around each attempt
    # of a trial; one trial has one attached at a time. O(1) per attempt.
    module Recording
      @recorders = {}
      @lock = Mutex.new

      class << self
        # The seam's call.
        def attempt_finished(attempt)
          recorder = @lock.synchronize { @recorders[attempt.trial] }
          recorder&.record(attempt)
        end

        # Runs the block with `recorder` attached for its trial; returns the
        # block's value. ArgumentError when its trial has one attached.
        def attach(recorder)
          raise ArgumentError, "block required" unless block_given?

          trial = recorder.trial_id
          @lock.synchronize do
            raise ArgumentError, "trial #{trial} already has a recorder attached" if @recorders.key?(trial)

            @recorders[trial] = recorder
          end
          begin
            yield
          ensure
            @lock.synchronize { @recorders.delete(trial) if @recorders[trial].equal?(recorder) }
          end
        end
      end
    end
  end
end
