# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # Holm across every candidate named, fed by each comparison's own
      # p-value (a candidate not compared counts with p = 1); each compared
      # candidate recomputed at its Holm level. O(m n + m log m) for m
      # candidates of n samples.
      class ComparisonSetBuilder
        def initialize(comparer, rows, label:, level:, no_worse_margin:)
          @comparer = comparer
          @rows = rows
          @label = label
          @level = level
          @no_worse_margin = no_worse_margin
          @alpha = 1 - level
        end

        def call
          @pairings = @rows.map { |_, samples, _| samples && @comparer.pairing(samples) }
          @p_values = @pairings.map { |pairing| pairing ? @comparer.p_value(pairing) : 1.0 }
          @adjusted, = Formulas.holm(@p_values, alpha: @alpha)
          @levels = holm_levels
          candidates = @rows.each_index.map { |index| candidate(index) }
          ComparisonSet.new(**heading, candidates:, inputs_digest: digest(candidates))
        end

        private

        def m = @rows.size

        # A rejected candidate at rank j gets 1 - alpha/(m - j + 1); every
        # other the level at which Holm stopped, 1 - alpha/(m - k + 1).
        def holm_levels
          stop = Formulas.holm_stop(@p_values, @alpha)
          levels = Array.new(m)
          Formulas.holm_order(@p_values).each_with_index do |index, rank|
            levels[index] = 1 - (@alpha / (m - [rank, stop].min))
          end
          levels
        end

        def candidate(index)
          label, samples, reason = @rows[index]
          pairing = @pairings[index]
          return not_compared(label, reason) unless pairing

          comparison = @comparer.comparison(pairing, samples, @levels[index], nil)
          ComparisonSet::Candidate.new(label:, status: "compared", reason_code: nil, p_value: @p_values[index],
                                       adjusted_p: @adjusted[index], level: @levels[index], comparison:,
                                       verdict: comparison.verdict, no_worse: no_worse(pairing))
        end

        def not_compared(label, reason)
          ComparisonSet::Candidate.new(label:, status: "not_compared", reason_code: reason, p_value: nil,
                                       adjusted_p: nil, level: nil, comparison: nil, verdict: nil, no_worse: nil)
        end

        # Its own family: each lower bound at 1 - alpha/m, Bonferroni over
        # every candidate named, never Holm's superiority levels.
        def no_worse(pairing)
          return unless @no_worse_margin

          Comparer.no_worse(@no_worse_margin, no_worse_level, pairing.interval(no_worse_level).first)
        end

        def no_worse_level = 1 - (@alpha / m)

        def heading
          { measure: baseline_estimate.measure, reducer: @comparer.reducer.name,
            method_name: @comparer.reducer.binary? ? "newcombe_paired" : "t_paired", method_revision: 1,
            confidence: @level, margin: @comparer.margin,
            adjustment: { "method" => "holm", "method_revision" => 1, "comparisons" => m,
                          "family_confidence" => @level },
            no_worse_margin: @no_worse_margin, no_worse_adjustment: no_worse_adjustment,
            baseline: { "label" => @label, "estimate" => baseline_estimate }, warnings: [] }
        end

        def baseline_estimate
          @baseline_estimate ||= Estimator.new(@comparer.base,
                                               Request.at(@comparer.reducer, @comparer.scale, @level)).call
        end

        def no_worse_adjustment
          @no_worse_margin && { "method" => "bonferroni", "comparisons" => m, "level" => no_worse_level }
        end

        def digest(candidates)
          InputsDigest.call("compare_many",
                            { "reducer" => @comparer.reducer.name, "scale" => @comparer.scale,
                              "margin" => @comparer.margin, "confidence" => @level, "adjustment" => "holm",
                              "no_worse_margin" => @no_worse_margin },
                            { "baseline" => [baseline_estimate.inputs_digest],
                              "candidates" => candidates.map { |row| row.comparison&.inputs_digest } })
        end
      end
      private_constant :ComparisonSetBuilder
    end
  end
end
