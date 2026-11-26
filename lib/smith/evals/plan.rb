# frozen_string_literal: true

require_relative "../scope"
require_relative "configuration"
require_relative "errors"
require_relative "identity"
require_relative "reducers"
require_relative "statistics"
require_relative "drivers/in_process"

module Smith
  module Evals
    # Experimental. What an eval run will do (slice-1a design, 5.7 and 8.6),
    # checked before anything is written: the suite's manifest and its
    # selection (the dataset verified, the samples sorted by id), the driver
    # (the run's, else the suite's, else Smith's in-process one), the
    # recording bounds a new run's header records, the trials in their
    # order and the plan digest a start with a known id or key must match.
    #
    # Refuses with the suite's and the dataset's own errors (SuiteInvalid,
    # SplitNotAllowed, DatasetInvalid, DatasetChanged), SubjectNotReady when
    # the subject's runtime readiness is :not_ready, DriverUnsupported for a
    # driver that is not in process, and SuiteInvalid for a pass_at_<k> or
    # pass_all_<k> reducer whose bootstrap over the selection would pass
    # Statistics::MAX_BOOTSTRAP_WORK (resamples times samples), which the
    # summary could then not be built with. O(N) in the samples, after the
    # dataset is read.
    class Plan
      attr_reader :suite, :scope, :selection, :driver, :scorers, :recording

      def initialize(suite, scope:, driver: nil, recording: Configuration::RECORDING_DEFAULTS)
        @suite = suite
        @scope = Smith::Scope.build(scope)
        @selection = suite.selection(scope: @scope)
        @driver = driver || suite.driver || Drivers::InProcess.new
        ready!
        bootstrap_fits!
        @scorers = suite.scorers
        @recording = Configuration.recording({ content: manifest.dig("recording", "content") }, from: recording)
        freeze
      end

      def manifest = selection.manifest
      def samples = selection.samples
      def subject = suite.subject
      def split = manifest.dig("selection", "split")
      def trials_per_sample = manifest.dig("trials", "per_sample")
      def error_retries = manifest.dig("trials", "error_retries")
      def infrastructure_errors = suite.infrastructure_errors
      def planned_trials = samples.size * trials_per_sample

      # The suite's concurrency, capped by the driver's.
      def concurrency = [suite.concurrency, driver.max_concurrency].min

      # Every sample's trial 0, then every sample's trial 1, and so on, so a
      # run that stops early has covered as many samples as it could:
      # [trial index, sample] pairs.
      def trials = (0...trials_per_sample).flat_map { |index| samples.map { [index, _1] } }

      def digest
        Identity.plan_digest(suite: manifest.fetch("version"), dataset: selection.dataset.version,
                             samples: selection.sample_ids_digest, split:, trials_per_sample:)
      end

      private

      def ready!
        form = driver.class.form if driver.class.respond_to?(:form)
        unless form == :in_process
          raise DriverUnsupported, "#{driver.class} runs #{form.inspect} trials; this runner runs them in process"
        end

        readiness = subject.workflow.runtime_readiness
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

      def not_ready!(errors)
        codes = errors.map(&:code).uniq.join(", ")
        raise SubjectNotReady, "#{subject.workflow.name} is not ready to run (#{codes}): see its runtime_readiness"
      end
    end
  end
end
