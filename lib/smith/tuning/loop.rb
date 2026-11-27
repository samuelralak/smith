# frozen_string_literal: true

require_relative "loop/setup"
require_relative "loop/state"
require_relative "loop/stops"
require_relative "loop/iteration"

module Smith
  module Tuning
    # Experimental. The tuning loop (slice 5a design, sections 1 and 2): GEPA's
    # Algorithm 1 over Smith's eval runs, in one process.
    #
    #   loop = Loop.open(suite, settings:, scope:, store:, idempotency_key:, started_by:)
    #   loop.iterate! until loop.done?
    #   loop.finish! # => Smith::Tuning::Record
    #
    # `open` writes the header, or finds the run's record: then the header
    # must match (ResumeMismatch names what differs: any setting, the split,
    # the components and their base texts, the objective, the suite, the
    # dataset, the Smith or host code version), a finished run is returned
    # as it is, and one the cap stopped, or that was killed, goes on from
    # its lines. The loop holds nothing the store does not (Loop::State), so
    # a restored loop and a running one are the same object. Each iteration
    # is Loop::Iteration's; `done?` reads the stop rules (Loop::Stops);
    # `finish!` writes the summary. The run's lease is held from `open` to
    # `finish!` or `close`. `trials:` is the seam (Evaluation); by default
    # Smith's own, Evaluation::InProcess.
    class Loop
      include Iteration

      DIGESTED = %w[suite dataset subject objective components split settings environment].freeze

      class << self
        def open(suite, settings:, scope:, store:, idempotency_key: nil, started_by: nil, trials: nil)
          scope = Smith::Scope.build(scope)
          setup = Setup.build(suite, settings, scope, idempotency_key)
          started_by = Evals::Actor.from_h(started_by) if started_by.is_a?(Hash)
          created!(store, scope, setup.header(settings, scope:, started_by:, idempotency_key:))
          trials ||= setup.seam(suite, settings, scope:, store:, started_by:)
          new(store:, scope:, settings:, setup:, trials:)
        end

        private

        # The header kept: the one written now, or the stored one when it
        # matches.
        def created!(store, scope, header)
          return if store.create_tuning(scope:, header:) == :created

          stored = store.read_tuning_header(scope:, tuning_run_id: header["tuning_run_id"])
          return if stored["tuning_digest"] == header["tuning_digest"]

          fields = DIGESTED.reject { Record.digest(stored.slice(_1)) == Record.digest(header.slice(_1)) }
          raise Evals::ResumeMismatch.new("tuning run #{header["tuning_run_id"]} was started with other settings: " \
                                          "#{fields.join(", ")} differ", fields:)
        end
      end

      def initialize(store:, scope:, settings:, setup:, trials:)
        @store = store
        @scope = scope
        @settings = settings
        @setup = setup
        @trials = trials
        @summary = store.read_tuning_summary(scope:, tuning_run_id:)
        return if finished?

        @lease = store.acquire_lease(scope:, tuning_run_id:)
        @state = State.restore(store.each_tuning_line(scope:, tuning_run_id:).to_a, seed: setup.seed,
                                                                                    split: setup.split, settings:)
      end

      def tuning_run_id = @setup.tuning_run_id

      # Whether the run stops before another iteration: a stop already
      # met, or a stop rule.
      def done?
        return true if finished? || @state.stop

        cancel = @store.cancel_request(scope: @scope, tuning_run_id:)
        stop = Stops.check(@state, @settings, cancel:, validation: @setup.split.validation_ids.size)
        @state.stopped(stop) if stop
        !stop.nil?
      end

      # Writes the summary, releases the lease and returns the record; a
      # finished run's record as it is.
      def finish!
        return record if finished?
        raise ArgumentError, "the run has not stopped: iterate until done?" unless @state.stop

        @store.write_tuning_summary(scope: @scope, tuning_run_id:, summary:, lease: @lease)
        close
        record
      end

      def close = @lease&.release

      private

      def finished? = !@summary.nil? && @summary["status"] != "stopped"

      def record = Tuning.record(tuning_run_id, scope: @scope, store: @store)

      def summary
        best = @state.pool.best unless @state.pool.empty?
        status, ended = Stops.ended(@state.stop, best)
        Record.summary(tuning_run_id:, scope: @scope, revision: @summary.to_h.fetch("summary_revision", 0) + 1,
                       status:, ended:, stop: @state.stop, **counts, seed: best && mark(0), best: best && mark(best),
                       warnings:)
      end

      # A scorer that gives no feedback text leaves the reflection its
      # explanations alone.
      def warnings = @setup.scorer.feedback? ? [] : [:feedback_weak]

      def counts
        totals = @state.totals
        { iterations: @state.iterations, candidates: @state.pool.size, metric_calls_used: totals.metric_calls,
          validation_passes: @state.validation_passes, usage: totals.usage }
      end

      def mark(index) = [@state.pool[index], index, @state.pool.mean(index)]

      def append(line)
        @store.append_tuning_line(scope: @scope, tuning_run_id:, line:, lease: @lease)
        line
      end
    end
  end
end
