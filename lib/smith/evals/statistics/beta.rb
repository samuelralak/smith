# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (x, a, b, m)

module Smith
  module Evals
    module Statistics
      module Distributions
        # The regularized incomplete beta I_x(a, b) by its continued fraction
        # (DLMF 8.17.22), evaluated by the modified Lentz method with the
        # prefactor of PowerTerms. The fraction needs about 530 iterations
        # near the middle at shapes of 10**6 + 1, the largest the interface
        # reaches (a beta posterior over 1,000,000 samples, McNemar over
        # 1,000,000 pairs), and 660 at 2 * 10**6: 2,000 leaves room.
        module Beta
          FRACTION_ITERATIONS = 2_000
          TOLERANCE = 1e-15
          TINY = 1e-300

          class << self
            def regularized(x, a, b) = tails(x, a, b).first

            # [I_x(a, b), 1 - I_x(a, b)]: the fraction reads whichever of the
            # two converges at x, and the other is its complement.
            def tails(x, a, b)
              return [0.0, 1.0] if x <= 0
              return [1.0, 0.0] if x >= 1
              return upper_first(x, a, b) if x > (a + 1.0) / (a + b + 2.0)

              lower = PowerTerms.call(x, a, b) / a / fraction(x, a, b)
              [lower, 1.0 - lower]
            end

            def log_beta(a, b)
              Math.lgamma(a).first + Math.lgamma(b).first - Math.lgamma(a + b).first
            end

            # log I_x(a, b), read in logs so a value below the smallest Float
            # keeps its digits.
            def log_lower(x, a, b)
              return Math.log(tails(x, a, b).first) if x > (a + 1.0) / (a + b + 2.0)

              PowerTerms.log_call(x, a, b) - Math.log(a) - Math.log(fraction(x, a, b))
            end

            # x**a (1 - x)**b / B(a, b). The density passes a - 1 and b - 1
            # with B(a, b) itself.
            def front(x, a, b, log_b = log_beta(a, b))
              Math.exp((a * Math.log(x)) + (b * Math.log(1.0 - x)) - log_b)
            end

            # 1 + d1/(1 + d2/(1 + ...)), two terms an iteration.
            def fraction(x, a, b)
              value = 1.0
              lentz = [1.0, 0.0]
              (1..FRACTION_ITERATIONS).each do |m|
                change = 1.0
                [(2 * m) - 1, 2 * m].each do |index|
                  lentz, delta = lentz_step(*lentz, term(index, x, a, b))
                  change *= delta
                end
                value *= change
                return value if (change - 1.0).abs < TOLERANCE
              end
              raise NotConverged, "the incomplete beta did not converge in #{FRACTION_ITERATIONS} iterations"
            end

            private

            # Past the middle the fraction reads 1 - I_x as I_(1-x)(b, a).
            def upper_first(x, a, b)
              upper = PowerTerms.call(1.0 - x, b, a) / b / fraction(1.0 - x, b, a)
              [1.0 - upper, upper]
            end

            def lentz_step(c, d, numerator)
              d = 1.0 + (numerator * d)
              d = TINY if d.abs < TINY
              c = 1.0 + (numerator / c)
              c = TINY if c.abs < TINY
              [[c, 1.0 / d], c / d]
            end

            def term(index, x, a, b)
              index.odd? ? odd_term(index / 2, x, a, b) : even_term(index / 2, x, a, b)
            end

            # d_(2m+1) = -(a + m)(a + b + m) x / ((a + 2m)(a + 2m + 1))
            def odd_term(m, x, a, b)
              -(a + m) * (a + b + m) * x / ((a + (2 * m)) * (a + (2 * m) + 1.0))
            end

            # d_(2m) = m (b - m) x / ((a + 2m - 1)(a + 2m))
            def even_term(m, x, a, b)
              m * (b - m) * x / ((a + (2 * m) - 1.0) * (a + (2 * m)))
            end
          end
        end
        private_constant :Beta

        # The fraction's prefactor x**a (1 - x)**b / B(a, b). Below
        # LARGE_SHAPE it is Beta.front, from Math.lgamma. From it, lgamma's
        # large values (and a log x) would cancel to about a * 1e-16 of it, so
        # with d = x (a + b) - a it is read as exp(a log1p(d/a) + b log1p(-d/b))
        # times sqrt(ab/(2 pi (a + b))) and Stirling's corrections: nothing
        # large cancels, as the two log1p terms are near d and -d.
        module PowerTerms
          LARGE_SHAPE = 10_000
          HALF_LOG_TWO_PI = 0.5 * Math.log(2 * Math::PI)
          # Stirling's correction log Gamma(z) - ((z - 1/2) log z - z + log(2 pi)/2)
          # = (1/z) * sum c_j / z**(2j), below 3e-17 from z = 10.
          STIRLING = [1 / 12r, -1 / 360r, 1 / 1260r, -1 / 1680r, 1 / 1188r, -691 / 360_360r, 1 / 156r]
                     .map(&:to_f).freeze

          class << self
            def call(x, a, b)
              return Beta.front(x, a, b) if [a, b].max < LARGE_SHAPE

              Math.exp(around_mean(x, a, b) + scale(a, b))
            end

            # log B(a, b); from LARGE_SHAPE in Stirling's form,
            # log(2 pi)/2 - a log1p(b/a) - b log1p(a/b) + log((a + b)/(ab))/2 plus
            # the corrections, where lgamma's large values would cancel.
            def log_beta(a, b)
              return Beta.log_beta(a, b) if [a, b].max < LARGE_SHAPE

              HALF_LOG_TWO_PI - shares(a, b) + (0.5 * Math.log((a + b) / (a * b))) + corrections(a, b)
            end

            # Its log, the same terms before exp.
            def log_call(x, a, b)
              return (a * Math.log(x)) + (b * Math.log(1.0 - x)) - Beta.log_beta(a, b) if [a, b].max < LARGE_SHAPE

              around_mean(x, a, b) + scale(a, b)
            end

            private

            # a log(x (a + b)/a) + b log((1 - x)(a + b)/b). Near the mean by
            # log1p of d/a and -d/b, so the two near-cancelling terms keep their
            # digits; where x (or 1 - x) is under half its share a/(a + b), that
            # log1p's argument nears -1 and loses them, so the term is read as
            # a (log x + log1p(b/a)) instead.
            def around_mean(x, a, b)
              deviation = (x * (a + b)) - a
              part(a, b, deviation / a) { Math.log(x) } + part(b, a, -deviation / b) { Math.log(1.0 - x) }
            end

            def part(shape, other, ratio)
              return shape * Precise.log1p(ratio) if ratio > -0.5

              shape * (yield + Precise.log1p(other / shape))
            end

            # a log((a + b)/a) + b log((a + b)/b).
            def shares(a, b) = (a * Precise.log1p(b / a)) + (b * Precise.log1p(a / b))

            # mu(a) + mu(b) - mu(a + b), Stirling's corrections.
            def corrections(a, b) = correction(a) + correction(b) - correction(a + b)

            # log(sqrt(ab/(2 pi (a + b)))) less the corrections of a and b, plus that of a + b.
            def scale(a, b)
              (0.5 * Math.log(a * b / (a + b))) - HALF_LOG_TWO_PI - correction(a) - correction(b) + correction(a + b)
            end

            def correction(z)
              return Math.lgamma(z).first - (((z - 0.5) * Math.log(z)) - z + HALF_LOG_TWO_PI) if z < 10

              square = 1.0 / (z * z)
              STIRLING.reverse.reduce { |sum, coefficient| (sum * square) + coefficient } / z
            end
          end
        end
        private_constant :PowerTerms

        # The x with I_x(a, b) = q: Newton steps on the gap, with the beta
        # density as derivative, kept inside a bisection bracket; at most 400.
        # Above q = 1/2 it solves 1 - I_x = 1 - q (exact there), so a q near 1
        # keeps its digits.
        module BetaQuantile
          ITERATIONS = 400
          # Below this, a lower-tail quantile is x**a/(a B(a, b)) = q itself:
          # the terms that formula leaves out are below 1e-30 of it.
          LOG_NEGLIGIBLE = Math.log(1e-30)
          # Below this q (far under the interface's least, 5.5e-17), the
          # solve is Newton on log I in log x, where log I is nearly linear.
          DEEP = 1e-20
          DEEP_STEPS = 200
          LOG_SMALLEST = Math.log(Float::MIN) - (52 * Math.log(2))

          class << self
            def call(target, a, b)
              tiny(target, a, b) || (target < DEEP ? deep(Math.log(target), a, b) : solve(target, a, b))
            end

            private

            # Bracketed in log x, bisected when a step leaves the bracket and
            # always after 100 steps, so it ends within 200.
            def deep(target, a, b)
              bracket = [LOG_SMALLEST, 0.0]
              u = deep_start(target, a, b)
              DEEP_STEPS.times do |count|
                following = deep_step(u, count, bracket, target, a, b)
                return Math.exp(following) if (following - u).abs <= 1e-15 * [1.0, u.abs].max

                u = following
              end
              Math.exp(bracket.sum / 2.0)
            end

            # deep's next log x, narrowing the bracket. The solver's state is
            # passed rather than held.
            def deep_step(u, count, bracket, target, a, b) # rubocop:disable Metrics/ParameterLists
              log_lower = Beta.log_lower(Math.exp(u), a, b)
              gap = log_lower - target
              return u if gap.zero?

              bracket[gap.positive? ? 1 : 0] = u
              newton = u - (gap / log_slope(u, a, b, log_lower))
              inside = count < DEEP_STEPS / 2 && newton > bracket.first && newton < bracket.last
              inside ? newton : bracket.sum / 2.0
            end

            # The lower of the mean's log and the root of x**a/(a B(a, b)) = q.
            def deep_start(target, a, b)
              [Math.log(a / (a + b)), (target + Math.log(a) + PowerTerms.log_beta(a, b)) / a].min
            end

            # d log I / d log x = x f(x) / I, the density f read in logs.
            def log_slope(u, a, b, log_lower)
              x = Math.exp(u)
              log_density = ((a - 1.0) * Math.log(x)) + ((b - 1.0) * Math.log(1.0 - x)) - PowerTerms.log_beta(a, b)
              Math.exp(u + log_density - log_lower)
            end

            def solve(target, a, b)
              upper = target > 0.5
              goal = upper ? 1.0 - target : target
              low = 0.0
              high = 1.0
              x = a / (a + b)
              ITERATIONS.times do
                gap = gap(x, a, b, goal, upper)
                return x if gap.zero?

                gap.negative? ? low = x : high = x
                following = step(x, gap, a, b, low..high)
                return following if settled?(following, x, low, high)

                x = following
              end
              raise NotConverged, "the beta quantile did not converge in #{ITERATIONS} steps"
            end

            # I_x - q, read as (1 - q) - (1 - I_x) above q = 1/2.
            def gap(x, a, b, goal, upper)
              lower_tail, upper_tail = Beta.tails(x, a, b)
              upper ? goal - upper_tail : lower_tail - goal
            end

            # A lower-tail root so small that I_x(a, b) = x**a/(a B(a, b)) to
            # within 1e-30, read in logs: 0.0 when it is below the smallest
            # Float; nil when it is not that small, as for every quantile the
            # interface asks (shapes of 1 or more, q above 1e-17).
            def tiny(target, a, b)
              return if target > 0.5

              root = (Math.log(target) + Math.log(a) + PowerTerms.log_beta(a, b)) / a
              Math.exp(root) if root + Math.log(a + b + 1.0) < LOG_NEGLIGIBLE
            end

            # Newton's step, with the beta density as derivative, when it
            # stays strictly inside the bracket; else the bracket's middle. A
            # step too small to move x leaves x where it is: converged.
            def step(x, gap, a, b, bracket)
              density = Beta.front(x, a - 1.0, b - 1.0, Beta.log_beta(a, b))
              newton = x - (gap / density) if density.finite? && density.positive?
              return newton if newton && (newton == x || (newton > bracket.begin && newton < bracket.end))

              (bracket.begin + bracket.end) / 2.0
            end

            def settled?(following, x, low, high)
              (following - x).abs <= Beta::TOLERANCE * following.abs || following == low || following == high
            end
          end
        end
        private_constant :BetaQuantile
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
