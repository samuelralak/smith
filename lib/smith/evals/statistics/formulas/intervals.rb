# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (p, n, a, b, c, d, k, x, y)

module Smith
  module Evals
    module Statistics
      module Formulas
        # Intervals for one proportion or mean.
        module Intervals
          # Wilson's score interval for a proportion p over a real size n:
          # [lower, upper], or [nil, nil] for no size. A closed form, written as
          # its paper writes it.
          def wilson(p:, n:, level:) # rubocop:disable Metrics/AbcSize
            return [nil, nil] unless n.positive?

            z = Distributions.normal_quantile((1 + level) / 2.0)
            divisor = 1 + (z * z / n)
            centre = (p + (z * z / (2 * n))) / divisor
            half = z * Math.sqrt([0.0, (p * (1 - p) / n) + (z * z / (4 * n * n))].max) / divisor
            [p.zero? ? 0.0 : centre - half, p == 1 ? 1.0 : centre + half]
          end

          # The interval of Beta(1 + s, 1 + n - s), a uniform prior, at a
          # level, holding the point it is shown with: s/n, its mode, unless
          # given (with no size there is no point, and the prior's interval
          # stands). Equal-tailed where that holds the point. When every
          # trial passed it is one-sided, from the quantile at 1 - level up
          # to 1, and when every trial failed, from 0 up to the quantile at
          # level. Elsewhere, where the equal-tailed interval leaves the
          # point out (near an end, or at a low level), it keeps its level
          # and moves toward the point until the point is its end.
          def beta_posterior(successes:, n:, level:, point: (successes.fdiv(n) if n.positive?))
            a = 1 + successes
            b = 1 + n - successes
            quantile = ->(q) { Distributions.beta_quantile(q, a, b) }
            return [quantile.call(1 - level), 1.0] if point == 1
            return [0.0, quantile.call(level)] if point&.zero?

            holding(point, level, quantile) { Distributions.incomplete_beta(point, a, b) }
          end

          # mean +/- t((1 + level)/2, n - 1) sd/sqrt(n), n real and above 1;
          # no spread is zero wide, and a t past the largest Float gives
          # [-Infinity, Infinity].
          def t_interval(mean:, sd:, n:, level:)
            return [mean, mean] if sd.zero?

            half = Distributions.t_quantile((1 + level) / 2.0, n - 1) * sd / Math.sqrt(n)
            [mean - half, mean + half]
          end

          # Whether every value is the same number, decided exactly: no spread
          # is computed, so equal values never read as varying by rounding.
          # Takes any Enumerable, lazy ones included, and stops at the first
          # value that differs.
          def equal_values?(values)
            first = values.first
            values.all? { |value| value == first }
          end

          # Type 7 (NumPy's default); nil for no values.
          def percentile(values, quantile)
            raise ArgumentError, "a percentile's q is in 0..1" unless quantile.between?(0, 1)
            return if values.empty?

            sorted_percentile(values.sort, quantile)
          end

          private

          # [lower, upper] holding mass level of a distribution given by its
          # quantile function: equal-tailed where that holds the point, or
          # there is none; otherwise moved toward the point, at the same
          # level, until the point is its end. The block, given whether the
          # interval moves up, returns the share of the distribution below
          # the point; it is read only then.
          def holding(point, level, quantile, &below)
            lower = quantile.call((1 - level) / 2.0)
            upper = quantile.call((1 + level) / 2.0)
            return [lower, upper] if point.nil? || point.between?(lower, upper)

            moved(point, level, quantile, point > upper, below)
          end

          # The interval of mass level ending at the point: its upper end
          # when rising, its lower end otherwise.
          def moved(point, level, quantile, rising, below)
            share = below.call(rising)
            return [[quantile.call([share - level, 0.0].max), point].min, point] if rising

            [point, [quantile.call([share + level, 1.0].min), point].max]
          end

          def sorted_percentile(sorted, quantile)
            position = (sorted.size - 1) * quantile
            low = position.floor
            sorted[low] + ((position - low) * (sorted[[low + 1, sorted.size - 1].min] - sorted[low]))
          end

          # Where the type 7 percentile curve of sorted values reaches a
          # value, as a share in 0..1: its first such share when rising, its
          # last otherwise; 1 past the largest value, 0 below the smallest.
          def percentile_rank(sorted, value, rising)
            last = sorted.size - 1
            above = sorted.bsearch_index { |draw| rising ? draw >= value : draw > value }
            return 1.0 if above.nil?
            return 0.0 if above.zero?

            before = sorted[above - 1]
            (above - 1 + ((value - before) / (sorted[above] - before))).clamp(0, last) / last
          end
        end
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
