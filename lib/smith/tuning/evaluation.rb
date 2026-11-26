# frozen_string_literal: true

module Smith
  module Tuning
    # Experimental. The loop's one seam to the runner (slice 5a design,
    # section 2: evaluation.rb and reflection.rb). The loop asks two things
    # of it, and nothing else:
    #
    #   evaluate(candidate, sample_ids:, kind:, key:, component: nil) # => Evaluation::Pass
    #   reflect(message, trial_id:)                                    # => Reflection::Call
    #
    # `evaluate` runs the candidate (its texts through
    # Smith::Prompts.with_candidate, its `reference` in the eval header) on
    # the given samples of the suite's selection, one trial each, as one
    # eval run of `kind` (:tuning_minibatch or :tuning_validation) whose
    # idempotency key is `key` ("<tuning run id>/<iteration>/<role>"): the
    # same key again gives the same pass and runs no recorded trial. Every
    # trial is fresh: no score is reused from another eval run. A sample's
    # score is the objective scorer's value; a failed subject or an errored
    # trial scores 0. With `component:` (a minibatch, training samples only)
    # each sample also carries the scorer's feedback for that component and
    # its trial's step records; without it neither is asked for or kept,
    # so validation gives the search numbers, never text. A trial that did
    # not run is left out: the pass is then not `complete`, and `stop` says
    # why (:cap_reached, :cancelled). It checks that every step of a
    # changed component carries the candidate's version, else `stop` is
    # :candidate_not_sent, and that every trial was scored, else
    # :scorer_failed. A known key asked for another candidate or other
    # samples raises Smith::Evals::ResumeMismatch, as the runner does.
    #
    # `reflect` makes an iteration's one reflection call as a recorded
    # trial with `trial_id` (Evals::Identity.reflection_trial_id): Smith's
    # named prompt (Reflection::PROMPT) as the instructions, `message`
    # (Reflection.message) as the user turn, the reflection model and
    # settings of the run's Settings, under their budget ledger. A call the
    # cap refuses has `stop` :cap_reached (or :cancelled) and ends the
    # tuning run; a model's failure has a `failure` and no `stop`, and ends
    # only its iteration.
    #
    # Smith's own implementation is built on Smith::Evals.run and the
    # in-process driver; a spec's stub answers from tables.
    module Evaluation
      METHODS = %i[evaluate reflect].freeze

      # One sample's result: its score (0 to 1), and for a minibatch the
      # scorer's feedback (a String or nil) and the trial's step records.
      Sample = Data.define(:score, :feedback, :steps)

      # One evaluation: its eval run, each sample that ran (by id, in the
      # order given), the metric calls it made (trials that ran, scored or
      # not), the provider calls they made, its cost, whether every sample
      # ran, and why the tuning run must stop (nil, or a Symbol).
      Pass = Data.define(:eval_run_id, :samples, :metric_calls, :provider_calls, :cost_nanos, :cost_complete,
                         :complete, :stop) do
        def scores = samples.transform_values(&:score)
        def mean = samples.empty? ? nil : scores.values.sum / samples.size
      end

      # Whether an object answers the seam.
      def self.seam?(object) = METHODS.all? { object.respond_to?(_1) }
    end
  end
end
