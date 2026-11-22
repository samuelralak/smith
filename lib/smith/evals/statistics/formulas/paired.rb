# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (p, n, a, b, c, d, k, x, y)

module Smith
  module Evals
    module Statistics
      module Formulas
        # Paired comparisons (design 7.5).
        module Paired
          EXACT_LIMIT = 1_000

          # Newcombe (1998b) method 10 for a paired table: a both pass, b the
          # candidate only, c the baseline only, d neither. [difference,
          # lower, upper] for (a + b)/n - (a + c)/n, with the adjusted psi of
          # R's contingencytables. A closed form, written as its paper writes it.
          def newcombe(a:, b:, c:, d:, level:) # rubocop:disable Metrics/AbcSize
            n = a + b + c + d
            raise ArgumentError, "newcombe needs at least one pair" unless n.positive?

            p1 = (a + b).fdiv(n)
            p2 = (a + c).fdiv(n)
            l1, u1 = wilson(p: p1, n:, level:)
            l2, u2 = wilson(p: p2, n:, level:)
            psi = newcombe_psi(a, b, c, d)
            [p1 - p2, p1 - p2 - root(p1 - l1, u2 - p2, psi), p1 - p2 + root(p2 - l2, u1 - p1, psi)]
          end

          # McNemar's exact test: min(1, 2 P(X <= min(b, c))), X ~ Bin(b + c, 1/2):
          # exact Rational sums up to b + c = 1,000, the incomplete beta above.
          # b = c gives exactly 1, since P(X <= (b + c)/2) is above one half.
          def mcnemar_exact(b:, c:)
            counts = [b, c]
            raise ArgumentError, "mcnemar_exact takes counts" unless counts.all? { _1.is_a?(Integer) && _1 >= 0 }
            return 1.0 if b == c

            [2 * binomial_tail(b + c, [b, c].min), 1].min.to_f
          end

          # Paired t on d = y - x (candidate minus baseline): the mean
          # difference, its interval, and the classic two-sided p. Equal
          # differences, found exactly, are a zero-wide interval at their value.
          def t_paired(x, y, level: 0.95)
            raise ArgumentError, "t_paired takes two lists of one length, at least 2" if x.size != y.size || x.size < 2

            equal_pairs(x, y) || varied_pairs(y.zip(x).map { |after, before| after - before }, level)
          end

          # The classic two-sided p of a paired t statistic.
          def t_test_p(mean, sd, n)
            [2 * Distributions.t_sf((mean / (sd / Math.sqrt(n))).abs, n - 1), 1.0].min
          end

          private

          # Equal differences, found exactly: a zero-wide interval at their value.
          def equal_pairs(x, y)
            exact = y.each_index.lazy.map { |index| Rational(y[index]) - Rational(x[index]) }
            return unless equal_values?(exact)

            point = exact.first.to_f
            { point:, lower: point, upper: point, p_value: point.zero? ? 1.0 : 0.0 }
          end

          def varied_pairs(differences, level)
            mean, sd = mean_and_sd(differences)
            return { point: mean, lower: mean, upper: mean, p_value: mean.zero? ? 1.0 : 0.0 } if sd.zero?

            lower, upper = t_interval(mean:, sd:, n: differences.size, level:)
            { point: mean, lower:, upper:, p_value: t_test_p(mean, sd, differences.size) }
          end

          # The mean and the sample standard deviation (divide by n - 1).
          def mean_and_sd(values)
            mean = values.sum.fdiv(values.size)
            [mean, Math.sqrt(values.sum { |value| (value - mean)**2 } / (values.size - 1))]
          end

          # Newcombe's adjusted psi: a closed form, written as its paper writes it.
          def newcombe_psi(a, b, c, d) # rubocop:disable Metrics/AbcSize
            n = a + b + c + d
            product = (a + b) * (c + d) * (a + c) * (b + d)
            cross = (a * d) - (b * c)
            return 0.0 if product.zero? || cross.between?(0, n / 2.0)

            (cross > n / 2.0 ? cross - (n / 2.0) : cross) / Math.sqrt(product)
          end

          # A square root that rounding drove below zero is taken as zero.
          def root(left, right, psi)
            Math.sqrt([0.0, (left**2) + (right**2) - (2 * psi * left * right)].max)
          end

          # P(X <= k) for X ~ Bin(n, 1/2).
          def binomial_tail(n, k)
            return Distributions.incomplete_beta(0.5, n - k, k + 1) if n > EXACT_LIMIT

            coefficient = 1
            head = (0..k).sum do |i|
              term = coefficient
              coefficient = coefficient * (n - i) / (i + 1)
              term
            end
            Rational(head, 2**n)
          end
        end
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
