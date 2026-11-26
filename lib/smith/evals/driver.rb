# frozen_string_literal: true

module Smith
  module Evals
    # Experimental; the in-process form is frozen with slice 1a.4. How one
    # trial of a subject runs (slice-1a design, 4.9): `run(trial, context)`
    # runs it inside Smith::Evals.under(context) and returns a
    # SubjectResult; anything it raises itself is the driver's own failure
    # (driver_error, or scope_conflict for a ScopeConflict). `around_trial`
    # wraps every attempt of a trial in the driver's isolation (a rolled-back
    # transaction, say); the runner never runs more than `max_concurrency`
    # trials at once. Slice 3a adds the :across_processes form (5.3).
    class Driver
      def self.form = :in_process

      def max_concurrency = 1

      # :around_trial when a subclass gives its own around_trial.
      def isolation = self.class.instance_method(:around_trial).owner == Driver ? :none : :around_trial

      def around_trial(_trial) = yield

      # How the runner waits before a trial's retry after an error: :sleep,
      # a backoff of min(30, 2**attempt) seconds, or :immediate, none.
      def retry_waits = :sleep

      def run(_trial, _context)
        raise NotImplementedError, "#{self.class} defines run(trial, context), returning a SubjectResult"
      end
    end
  end
end
