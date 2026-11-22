# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      module Formulas
        # Korn and Graubard's design effect, and the cluster-aware bootstrap.
        module Clusters
          # The design effect for the mean of values grouped by keys:
          # [design effect, clusters, applies]. It applies when some key holds
          # two values or more. One key holding every value is one independent
          # unit, so the design effect is n and n over it is 1 (K/(K - 1) has
          # no value at K = 1; the slice 1a.1 review ruled the cautious
          # reading). Otherwise it is 1 when the values do not vary, and never
          # below 1. The cluster-robust variance carries K/(K - 1) and the
          # independent one no such factor.
          def design_effect(values, keys)
            groups = values.each_index.group_by { |index| keys[index] }.values
            return [1.0, groups.size, false] if groups.size == values.size
            return [values.size.to_f, 1, true] if groups.size == 1

            [variance_ratio(values, groups), groups.size, true]
          end

          # The percentile bootstrap of design 7.2: clusters in UTF-16 order
          # of their keys, K drawn with replacement per resample, each
          # resample the drawn values' sum over their count; seed an Integer.
          # The interval holds the values' mean, the point it is shown with:
          # where the resamples' percentiles leave it out (at a low level,
          # or by a resample of the data itself summing to another
          # rounding), it moves at its level until the mean is its end.
          def cluster_bootstrap(values:, keys:, resamples:, seed:, level:)
            draws = resample(cluster_totals(values, keys), resamples, SplitMix64.new(seed)).sort!
            point = values.sum.fdiv(values.size)
            holding(point, level, ->(q) { sorted_percentile(draws, q) }) do |rising|
              percentile_rank(draws, point, rising)
            end
          end

          private

          # Cluster-robust variance over independent-sampling variance, at
          # least 1; 1 when the values do not vary. Equal values are found
          # exactly first, so both variances are exactly zero for them, never
          # rounding left over from a mean that is not exact.
          def variance_ratio(values, groups)
            return 1.0 if equal_values?(values)

            mean = values.sum.fdiv(values.size)
            independent = values.sum { |value| (value - mean)**2 } / values.size / values.size
            return 1.0 if independent.zero?

            [1.0, clustered_variance(values, groups, mean) / independent].max
          end

          # [sum, count] per cluster, clusters in UTF-16 order of their keys.
          def cluster_totals(values, keys)
            groups = values.each_index.group_by { |index| keys[index] }
            groups.keys
                  .sort_by { |key| key.encode(Encoding::UTF_16BE).b }
                  .map { |key| [groups[key].sum { |index| values[index] }, groups[key].size] }
          end

          # K/(K - 1) * sum_k S_k**2 / n**2, S_k the sum of v - mean in cluster k.
          def clustered_variance(values, groups, mean)
            squares = groups.sum { |group| group.sum { |index| values[index] - mean }**2 }
            groups.size.fdiv(groups.size - 1) * squares / (values.size * values.size)
          end

          def resample(totals, resamples, generator)
            Array.new(resamples) do
              sum = 0.0
              count = 0
              totals.size.times do
                drawn, size = totals[generator.below(totals.size)]
                sum += drawn
                count += size
              end
              sum / count
            end
          end
        end
      end
    end
  end
end
