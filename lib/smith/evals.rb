# frozen_string_literal: true

require_relative "../smith"
require_relative "evals/statistics"
require_relative "evals/errors"
require_relative "evals/actor"
require_relative "evals/configuration"
require_relative "evals/identity"
require_relative "evals/store"
require_relative "evals/stores/memory"
require_relative "evals/stores/file"
require_relative "evals/split_rule"
require_relative "evals/sample"
require_relative "evals/dataset_manifest"
require_relative "evals/file_dataset"
require_relative "evals/dataset"
require_relative "evals/score"
require_relative "evals/reducers"
require_relative "evals/scorer"
require_relative "evals/subject"
require_relative "evals/suite_manifest"
require_relative "evals/suite"
require_relative "evals/trial_context"
require_relative "evals/trial_spec"
require_relative "evals/subject_result"
require_relative "evals/trial"
require_relative "evals/outcomes"
require_relative "evals/recorder"
require_relative "evals/recording"
require_relative "evals/driver"
require_relative "evals/drivers/in_process"
require_relative "evals/spend"
require_relative "evals/summary"
require_relative "evals/record"
require_relative "evals/eval_run"
require_relative "evals/plan"
require_relative "evals/runner"

module Smith
  # Experimental. Evals: datasets, scorers, suites, the store, running one
  # trial (its spec and context, the in-process driver, the recorder and
  # outcome classification) and running a suite to its record, loaded only
  # by `require "smith/evals"` (slice-1a design), never by `require
  # "smith"`. Loading it installs Smith::Evals::Recording into the core's
  # attempt seam; outside a trial (Smith::Evals.under) the seam calls
  # nothing.
  module Evals
    EXPERIMENTAL = true

    class << self
      # Runs a suite in this process and returns its EvalRun (slice-1a
      # design, 4.6). The same idempotency key (or eval_run_id) resumes the
      # run, or returns it when it has finished, if its plan digest matches,
      # else raises ResumeMismatch. `scope` is the tenant (default
      # config.default_scope); `started_by` an Actor; `store` and `driver`
      # override the configuration's and the suite's. `samples` (ids within
      # the suite's selection), `trials` (a sample's), `candidate` (a tuning
      # candidate, sent in place of the base texts) and `kind` narrow or
      # name the run (Plan). The run reads a frozen copy of the
      # configuration taken now.
      def run(suite, scope: nil, idempotency_key: nil, eval_run_id: nil, started_by: nil, store: nil, driver: nil,
              samples: nil, trials: nil, candidate: nil, kind: :eval)
        config = self.config.frozen_copy
        plan = Plan.new(suite, scope: scope || config.default_scope, driver:, recording: config.recording,
                               samples:, trials:, candidate:, kind:)
        Runner.new(plan, store: store || config.store, config:)
              .call(eval_run_id:, idempotency_key:, started_by: started_by && actor(started_by))
      end

      # Asks a run to stop: its runner starts no trial after reading the
      # flag, records those running, and ends cancelled. The first request
      # stands: :requested, then :exists.
      def cancel(eval_run_id, actor:, reason: nil, scope: nil, store: nil)
        (store || config.store).request_cancel(scope: scope || config.default_scope, eval_run_id:, actor:, reason:)
      end

      # The run's Record, or nil when the store holds none in the scope.
      def record(eval_run_id, scope: nil, store: nil)
        Record.read(store: store || config.store, scope: Smith::Scope.build(scope || config.default_scope),
                    eval_run_id:)
      end

      private

      def actor(value) = value.is_a?(Actor) ? value : Actor.from_h(value)
    end

    # Runs the block inside the trial's scope (a TrialContext): every agent
    # attempt made in it, on any thread its steps use, reaches the recorder
    # attached for the trial. Returns the block's value. A host driver
    # calls it around whatever drives the subject.
    def self.under(context, &block)
      raise ArgumentError, "block required" unless block
      raise ArgumentError, "Smith::Evals.under takes a Smith::Evals::TrialContext" unless context.is_a?(TrialContext)

      Smith::Attribution.with(trial: context.trial_id, &block)
    end
  end
end

Smith::AttemptObservation.install(Smith::Evals::Recording)
