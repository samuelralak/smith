# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # Comparisons against one baseline (design 7.5): pairs a candidate,
      # reads its p-value from its interval, and builds its comparison at a
      # level, the verdict read from that same interval.
      class Comparer
        VERDICT_RULE = "interval_vs_margin/1"

        attr_reader :base, :reducer, :scale, :margin

        def initialize(base, reducer, scale, margin)
          @base = base
          @reducer = reducer
          @scale = scale
          @margin = margin
        end

        def pairing(other)
          pairing = Pairing.new(@base, other, @reducer)
          SampleList.bootstrap_work!(pairing.size, RESAMPLES) if @reducer.bootstrap?
          pairing
        end

        # The smallest alpha at which the interval excludes the threshold.
        def p_value(pairing)
          Formulas.interval_p(point: pairing.point, margin: @margin) { |level| pairing.interval(level) }
        end

        def comparison(pairing, other, level, no_worse_margin)
          difference = %w[point lower upper].zip([pairing.point, *pairing.interval(level)]).to_h
          verdict = verdict(difference)
          Comparison.new(**heading(pairing, level), **reading(pairing, difference, verdict),
                         no_worse: no_worse_margin && Comparer.no_worse(no_worse_margin, level, difference["lower"]),
                         inputs_digest: digest(other, level, no_worse_margin))
        end

        def self.no_worse(margin, level, lower)
          { "margin" => margin, "level" => level, "lower" => lower, "holds" => lower > -margin }
        end

        private

        def heading(pairing, level)
          request = Request.at(@reducer, @scale, level)
          { measure: @reducer.binary? ? "pass_rate" : "mean", reducer: @reducer.name,
            method_name: @reducer.binary? ? "newcombe_paired" : "t_paired", method_revision: 1, confidence: level,
            pairs: pairing.size, only_in_baseline: pairing.only_in_baseline,
            only_in_candidate: pairing.only_in_candidate,
            baseline: Estimator.new(pairing.baseline, request).call,
            candidate: Estimator.new(pairing.candidate, request).call }
        end

        def reading(pairing, difference, verdict)
          { margin: @margin, changed: pairing.changed, difference:, p_value: p_value(pairing), test: pairing.test,
            verdict:, verdict_rule: VERDICT_RULE, approximate: !pairing.binary? && pairing.size < 30,
            warnings: pairing.warnings(30),
            display: Display.difference(difference, verdict:, margin: @margin, unit: points_or_score) }
        end

        # "worse" means wholly below zero.
        def verdict(difference)
          return "better" if difference["lower"] > @margin

          difference["upper"].negative? ? "worse" : "inconclusive"
        end

        def points_or_score = @scale == "binary" ? "points" : "score"

        def digest(other, level, no_worse_margin)
          InputsDigest.call("compare", { "reducer" => @reducer.name, "scale" => @scale, "margin" => @margin,
                                         "confidence" => level, "no_worse_margin" => no_worse_margin },
                            { "baseline" => @base, "candidate" => other })
        end
      end
      private_constant :Comparer
    end
  end
end
