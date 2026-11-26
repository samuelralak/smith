# frozen_string_literal: true

require_relative "../reducers"

module Smith
  module Evals
    module Summary
      # Internal. summary.results: one entry for each scorer of the header's
      # manifest and each of its reducers (the headline, then `also`), each
      # with a smith.evals.stats/1 estimate over the samples it counted. A
      # trial counts for a scorer when its effective line has that scorer's
      # score and the score is scored (a pass or fail, or a value); an
      # unscored one is left out and counted apart. pass_at_<k> and
      # pass_all_<k> read k trials of a sample (design 4.4), so a sample
      # with fewer counted trials (an errored trial, a stopped run) is left
      # out of those results and counted in their samples_uncounted. O(T)
      # to gather, plus the estimates.
      class Results
        # header: the record's; samples: the selected samples (their clusters).
        def initialize(header, samples)
          @scorers = header.dig("suite", "manifest", "scorers")
          @statistics = header.fetch("statistics")
          @selected = header.dig("selection", "sample_count")
          @clusters = samples.to_h { [_1.id, _1.cluster] }
        end

        # trials: the effective lines' facts, in trial index order.
        def call(trials)
          @scorers.flat_map do |scorer|
            counted, unscored = gathered(trials, scorer)
            [scorer["reduce"], *scorer["also"]].map do |reducer|
              entry(scorer, reducer, read_by(counted, reducer), unscored)
            end
          end
        end

        private

        def entry(scorer, reducer, counted, unscored)
          { "scorer" => scorer["name"], "scorer_version" => scorer["version"], "scale" => scorer["scale"],
            "reducer" => reducer, "headline" => reducer == scorer["reduce"],
            "samples_uncounted" => @selected - counted.size, "trials_counted" => counted.values.sum(&:size),
            "trials_unscored" => unscored, "estimate" => estimate(scorer, reducer, counted).to_h }
        end

        # Each sample's counted trials (pass or fail, or a value as a Float),
        # and how many were unscored.
        def gathered(trials, scorer)
          scores = scores_of(trials, scorer["name"])
          counted = scores.select { |_id, score| score.first == "scored" }
          values = counted.group_by(&:first).transform_values { |list| list.map { value(_1.last, scorer["scale"]) } }
          [values, scores.size - counted.size]
        end

        # The samples a reducer reads: for pass_at_<k> and pass_all_<k>,
        # those with at least k counted trials.
        def read_by(counted, reducer)
          k = Reducers.k(reducer)
          k ? counted.select { |_id, trials| trials.size >= k } : counted
        end

        # [sample id, [status, passed, value]] for each trial the scorer has a score in.
        def scores_of(trials, name) = trials.filter_map { [_1.sample_id, _1.scores[name]] if _1.scores.key?(name) }

        def value((_status, passed, value), scale) = scale == "binary" ? passed : value.to_f

        def estimate(scorer, reducer, counted)
          samples = counted.map { |id, trials| Statistics::Sample.new(id:, trials:, cluster: @clusters[id]) }
          Statistics.estimate(samples:, reducer:, scale: scorer["scale"].to_sym, confidence: @statistics["level"],
                              resamples: @statistics["bootstrap_resamples"],
                              small_sample_threshold: @statistics["small_sample_threshold"])
        end
      end
    end
  end
end
