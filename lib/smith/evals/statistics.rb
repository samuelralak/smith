# frozen_string_literal: true

require_relative "../error"
require_relative "../canonical_json"
require_relative "statistics/split_mix64"
require_relative "statistics/distributions"
require_relative "statistics/beta"
require_relative "statistics/student_t"
require_relative "statistics/formulas"
require_relative "statistics/display"
require_relative "statistics/results"
require_relative "statistics/sample"
require_relative "statistics/inputs"
require_relative "statistics/sample_list"
require_relative "statistics/inputs_digest"
require_relative "statistics/estimation"
require_relative "statistics/resampling"
require_relative "statistics/estimator"
require_relative "statistics/pairing"
require_relative "statistics/comparer"
require_relative "statistics/comparing"
require_relative "statistics/comparison_set_builder"
require_relative "statistics/sizing"
require_relative "statistics/judging"

module Smith
  module Evals
    # Smith's statistics: one module of pure functions, loaded alone by
    # `require "smith/evals/statistics"` (no workflow code, no observer, no
    # I/O, no global state), so a product's web process can use it without
    # the rest of the engine (slice-1a design, section 7).
    #
    #   S = Smith::Evals::Statistics
    #   samples = [S::Sample.new(id: "s-17", trials: [true, true, false], cluster: "person-4"), ...]
    #   S.estimate(samples:, reducer: :majority).to_h # => a smith.evals.stats/1 estimate
    #
    # A host says what it measured and hands over the data; Smith picks the
    # interval (Wilson, the beta posterior or t on the effective sample size;
    # a cluster-aware bootstrap only for pass@k and pass^k), so two screens
    # cannot disagree. Each function checks its inputs and raises
    # ArgumentError outside its domain before any work, and returns a frozen
    # result whose `to_h` is its smith.evals.stats/1 form. A confidence is
    # above 0 and at most MAX_CONFIDENCE, 0.999999999; a baseline and a
    # power are strictly between 0 and 1; a margin is at least 0. Every
    # interval holds the point it is shown with. Inputs digests and
    # bootstraps are exact everywhere (SHA-256, integer SplitMix64 draws);
    # the closed forms read the platform's exp, log and lgamma, so the same
    # inputs give the same bytes in any process on one platform, and agree
    # across platforms to about 1e-14.
    #
    # estimate, rate, detectable, required_samples and judge_check are frozen
    # with slice 1a.1; compare and compare_many are experimental until slice
    # 1b freezes them. The formulas underneath (Formulas, Distributions) are
    # experimental until slice 6.
    module Statistics
      SCHEMA = "smith.evals.stats/1"
      # The warning codes Smith writes today. The list is open: a reader
      # shows an unknown code as "uncertain".
      WARNINGS = %w[small_sample few_clusters uneven_trials no_variation interval_clipped no_samples
                    unpaired_samples zero_discordant clusters_ignored too_few_units].freeze
      MAX_SAMPLES = 1_000_000
      MAX_TRIALS = 1_000
      MAX_CANDIDATES = 64
      MAX_BOOTSTRAP_WORK = 100_000_000
      # The fewest resamples a bootstrap takes: fewer read noise as certainty.
      MIN_RESAMPLES = 100
      # The highest confidence taken. compare_many reads up to 64 candidates
      # at 1 - (1 - confidence)/m; up to here each such level keeps
      # (1 + level)/2, where the quantiles are read, below 1, and its alpha
      # above the 1e-12 floor of the p-values Holm compares it with.
      MAX_CONFIDENCE = 0.999999999
      # Resamples for the estimates inside a comparison.
      RESAMPLES = 2_000
      # The correlation between two runs behind low, typical and high sizes.
      CORRELATIONS = { "low" => 0.7, "typical" => 0.5, "high" => 0.3 }.freeze

      # A distribution function that did not converge in its bounded steps.
      class NotConverged < Smith::Error; end

      extend Estimation
      extend Comparing
      extend Sizing
      extend Judging
    end
  end
end
