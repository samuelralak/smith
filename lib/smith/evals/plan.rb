# frozen_string_literal: true

require_relative "../scope"
require_relative "configuration"
require_relative "errors"
require_relative "identity"
require_relative "reducers"
require_relative "statistics"
require_relative "drivers/in_process"
require_relative "plan/checks"

module Smith
  module Evals
    # Experimental. What an eval run will do (slice-1a design, 5.7 and 8.6),
    # checked before anything is written: the suite's manifest and its
    # selection (the dataset verified, the samples sorted by id), the driver
    # (the run's, else the suite's, else Smith's in-process one), the
    # recording bounds a new run's header records, the trials in their
    # order and the plan digest a start with a known id or key must match.
    #
    # What slice 5a adds, all held here: `samples` narrows the selection to
    # the ids given (the header's narrowing, and what the run measured);
    # `trials` replaces the suite's trials a sample; `candidate` is a tuning
    # candidate (anything answering `reference`, the header's candidate,
    # and `texts`, a text for each component it names, each the version it
    # names), sent in place of the base texts, whose id is in the plan
    # digest and every trial id; `kind` is eval, tuning_minibatch or
    # tuning_validation.
    #
    # Refuses with the suite's and the dataset's own errors (SuiteInvalid,
    # SplitNotAllowed, DatasetInvalid, DatasetChanged), SubjectNotReady when
    # the subject's runtime readiness is :not_ready, DriverUnsupported for a
    # driver that is not in process, SuiteInvalid for a pass_at_<k> or
    # pass_all_<k> reducer whose bootstrap over the selection would pass
    # Statistics::MAX_BOOTSTRAP_WORK (resamples times samples), which the
    # summary could then not be built with, and ArgumentError for a
    # narrowing, trials, candidate or kind it does not take. O(N) in the
    # samples, after the dataset is read.
    class Plan
      attr_reader :suite, :scope, :selection, :driver, :scorers, :recording, :samples, :trials_per_sample,
                  :candidate, :kind

      def initialize(suite, scope:, driver: nil, recording: Configuration::RECORDING_DEFAULTS, samples: nil,
                     trials: nil, candidate: nil, kind: :eval)
        @suite = suite
        @scope = Smith::Scope.build(scope)
        @selection = suite.selection(scope: @scope)
        asked!(samples, trials, candidate, kind)
        @driver = driver || suite.driver || Drivers::InProcess.new
        ready!
        bootstrap_fits!
        @scorers = suite.scorers
        @recording = Configuration.recording({ content: manifest.dig("recording", "content") }, from: recording)
        freeze
      end

      def manifest = selection.manifest
      def subject = suite.subject
      def split = manifest.dig("selection", "split")
      def error_retries = manifest.dig("trials", "error_retries")
      def infrastructure_errors = suite.infrastructure_errors
      def planned_trials = samples.size * trials_per_sample
      def candidate_id = candidate&.reference&.fetch("candidate_id")

      # The suite's concurrency, capped by the driver's.
      def concurrency = [suite.concurrency, driver.max_concurrency].min

      # Every sample's trial 0, then every sample's trial 1, and so on, so a
      # run that stops early has covered as many samples as it could:
      # [trial index, sample] pairs.
      def trials = (0...trials_per_sample).flat_map { |index| samples.map { [index, _1] } }

      # The selection as the header names it: the ids given, else the suite's.
      def narrow = @narrowed ? { "ids" => Identity.utf16_sort(samples.map(&:id)) } : manifest.dig("selection", "narrow")
      def sample_ids_digest = @narrowed ? Identity.sample_ids_digest(samples.map(&:id)) : selection.sample_ids_digest

      # What the run measures: the suite's measure with this narrowing and
      # these trials.
      def measure_digest
        measured = manifest.merge("selection" => manifest["selection"].merge("narrow" => narrow),
                                  "trials" => manifest["trials"].merge("per_sample" => trials_per_sample))
        Identity.measure_digest(measured, dataset: selection.dataset.version, samples: sample_ids_digest)
      end

      # A trial's id in this plan: its candidate's id folded in.
      def trial_id(eval_run_id:, sample_id:, index:)
        Identity.trial_id(eval_run_id:, sample_id:, index:, candidate: candidate_id)
      end

      def digest
        Identity.plan_digest(suite: manifest.fetch("version"), dataset: selection.dataset.version,
                             samples: sample_ids_digest, split:, trials_per_sample:, candidate: candidate_id)
      end

      private

      # What slice 5a's arguments ask, each checked.
      def asked!(samples, trials, candidate, kind)
        @kind = Checks.kind!(kind)
        @candidate = Checks.candidate!(candidate)
        @narrowed = !samples.nil?
        @samples = @narrowed ? Checks.narrowed(selection.samples, samples) : selection.samples
        @trials_per_sample = trials.nil? ? manifest.dig("trials", "per_sample") : Checks.trials!(trials)
      end

      def ready!
        in_process!
        workflow = subject.workflow
        return no_workflow!(workflow) unless workflow < Smith::Workflow

        readiness = workflow.runtime_readiness
        not_ready!(readiness.errors) if readiness.status == :not_ready
      end

      def bootstrap_fits!
        resamples = manifest.dig("statistics", "bootstrap_resamples")
        return if samples.size * resamples <= Statistics::MAX_BOOTSTRAP_WORK || bootstrapped.empty?

        raise SuiteInvalid.new(["/statistics/bootstrap_resamples: #{bootstrapped.join(", ")} would bootstrap " \
                                "#{resamples} resamples of #{samples.size} samples, past the bound of " \
                                "#{Statistics::MAX_BOOTSTRAP_WORK} (resamples times samples)"],
                               suite: manifest["name"])
      end

      # The suite's pass_at_<k> and pass_all_<k> reducers.
      def bootstrapped = manifest["scorers"].flat_map { [_1["reduce"], *_1["also"]] }.select { Reducers.k(_1) }.uniq

      def in_process!
        form = driver.class.form if driver.class.respond_to?(:form)
        return if form == :in_process

        raise DriverUnsupported, "#{driver.class} runs #{form.inspect} trials; this runner runs them in process"
      end

      # A host driver runs any subject; Smith's own runs a workflow.
      def no_workflow!(workflow)
        return unless driver.is_a?(Drivers::InProcess)

        raise SubjectNotReady, "#{workflow.name} is no Smith::Workflow, which Smith's in-process driver runs; " \
                               "a host driver runs any subject"
      end

      def not_ready!(errors)
        codes = errors.map(&:code).uniq.join(", ")
        raise SubjectNotReady, "#{subject.workflow.name} is not ready to run (#{codes}): see its runtime_readiness"
      end
    end
  end
end
