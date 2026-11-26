# frozen_string_literal: true

require_relative "../scope"
require_relative "identity"
require_relative "trial_context"

module Smith
  module Evals
    # Experimental. What one attempt of one trial runs (slice-1a design,
    # 5.1): its id (the same across a relaunch, Identity.trial_id), the eval
    # run and its scope, the sample and trial index, the candidate (nil
    # until slice 5a), the suite's subject, the run's variant (nil until
    # slice 1b), the attempt (1, then 2 and more for retries after an
    # error) and a seed reserved for subjects that take one: the trial id's
    # first 8 hex digits as an Integer. Frozen.
    TrialSpec = Data.define(:trial_id, :eval_run_id, :scope, :sample, :trial_index, :candidate, :subject,
                            :variant, :attempt, :seed) do
      def self.for(eval_run_id:, scope:, sample:, trial_index:, subject:, attempt: 1, candidate: nil, variant: nil)
        raise ArgumentError, "a trial's attempt is an Integer of at least 1" unless attempt.is_a?(Integer) &&
                                                                                    attempt.positive?

        trial_id = Identity.trial_id(eval_run_id:, sample_id: sample.id, index: trial_index, candidate:)
        new(trial_id:, eval_run_id:, scope: Smith::Scope.build(scope), sample:, trial_index:, candidate:, subject:,
            variant:, attempt:, seed: trial_id[3, 8].to_i(16))
      end

      # What a driver hands Smith::Evals.under.
      def context
        TrialContext.new(trial_id:, eval_run_id:, scope:, sample_id: sample.id, trial_index:,
                         candidate_id: candidate)
      end
    end
  end
end
