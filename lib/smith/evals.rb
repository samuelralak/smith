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

module Smith
  # Experimental. Evals: datasets, scorers, suites, the store, and running
  # one trial (its spec and context, the in-process driver, the recorder
  # and outcome classification), loaded only by `require "smith/evals"`
  # (slice-1a design), never by `require "smith"`. Loading it installs
  # Smith::Evals::Recording into the core's attempt seam; outside a trial
  # (Smith::Evals.under) the seam calls nothing.
  module Evals
    EXPERIMENTAL = true

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
