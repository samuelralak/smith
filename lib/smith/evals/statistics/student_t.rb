# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (a, u, x, y, z, df)

module Smith
  module Evals
    module Statistics
      module Distributions
        # Student's t's quantile, within 1e-10 relative at every p and every
        # real df > 0. It is Newton's method in log t on the log of whichever
        # of StudentTails' two probabilities p gives exactly (the tails
        # beyond p = 0.25 and 0.75, the middle between), inside a bracket it
        # bisects whenever a step leaves it, and always after 100 steps, so it
        # ends in at most 200. From 1e5 degrees of freedom the Cornish-Fisher
        # expansion to 1/df**4 (Abramowitz and Stegun 26.7.5) replaces the
        # inversion: what it leaves out is below 1e-13 of t there, for every p
        # a Float holds. A quantile past the largest Float is Float::INFINITY.
        # The upper tail inverts the same expansion there (Newton for z, then
        # the normal's tail by erfc), since the continued fraction loses
        # about 1e-16 df / t**2 of it at large df: so the tail is within
        # 1e-10 relative too (1e-11 at worst, just below 1e5 df).
        module StudentT
          EXPANSION_DF = 1e5
          STEPS = 200
          BISECT_AFTER = 100
          LOG_LARGEST = Math.log(Float::MAX)
          LOG_SMALLEST = Math.log(Float::MIN) - (52 * Math.log(2))
          # The expansion's g_k(z) / z, as polynomials in z**2, lowest power first, and their divisors.
          EXPANSION = [[[1, 1], 4], [[3, 16, 5], 96], [[-15, 17, 19, 3], 384],
                       [[-945, -1920, 1482, 776, 79], 92_160]].freeze

          class << self
            # t's quantile for 0 < p < 1 and df > 0, both Floats.
            def quantile(prob, df)
              return 0.0 if (prob - 0.5).zero?
              return expansion(Normal.quantile(prob), df) if df >= EXPANSION_DF

              tail = prob < 0.5 ? prob : 1.0 - prob
              value = tail <= 0.25 ? solve(Math.log(2.0 * tail), df, :tails) : middle(tail, df)
              prob < 0.5 ? -value : value
            end

            # P(T > t) for a finite t.
            def upper(value, df)
              return 0.5 if value.zero?

              half = df >= EXPANSION_DF ? normal_tail(value.abs, df) : fraction_tail(value.abs, df)
              value.positive? ? half : 1.0 - half
            end

            private

            # z + g1/df + g2/df**2 + g3/df**3 + g4/df**4, the small terms first.
            def expansion(z, df)
              square = z * z
              terms = EXPANSION.each_with_index.map do |(coefficients, divisor), index|
                z * coefficients.reverse.reduce { |sum, coefficient| (sum * square) + coefficient } / divisor /
                  (df**(index + 1))
              end
              z + terms.reverse.sum
            end

            def fraction_tail(value, df) = Math.exp(StudentTails.logs(Math.log(value), df).first) / 2.0

            # P(Z > z) for the z the expansion takes to t: Newton from the
            # expansion's first term, a few steps, its slope near 1.
            def normal_tail(value, df) = Math.erfc(expansion_root(value, df) / Math.sqrt(2.0)) / 2.0

            def expansion_root(value, df)
              z = value / (1.0 + (((value * value) + 1.0) / (4.0 * df)))
              8.times do
                step = (expansion(z, df) - value) / expansion_slope(z, df)
                z -= step
                break if step.abs <= 1e-16 * z.abs
              end
              z
            end

            # d/dz of the expansion: 1 + sum (P_k(z**2) + 2 z**2 P_k'(z**2)) / df**k,
            # where g_k(z) = z P_k(z**2).
            def expansion_slope(z, df)
              square = z * z
              terms = EXPANSION.each_with_index.map do |(coefficients, divisor), index|
                value, slope = polynomial(coefficients, square)
                (value + (2.0 * square * slope)) / divisor / (df**(index + 1))
              end
              1.0 + terms.reverse.sum
            end

            # [P(s), P'(s)] by Horner's rule, the coefficients lowest power first.
            def polynomial(coefficients, square)
              coefficients.reverse.reduce([0.0, 0.0]) do |(value, slope), coefficient|
                [(value * square) + coefficient, (slope * square) + value]
              end
            end

            # 1 - 2 tail is exact for a tail between 0.25 and 0.5.
            def middle(tail, df) = solve(Math.log(1.0 - (2.0 * tail)), df, :middle)

            # The t whose log F(t) is target, F the tails (falling in log t)
            # or the middle (rising), or infinity past the largest Float.
            def solve(target, df, form)
              rising = form == :middle
              return Float::INFINITY if beyond?(target, df, form, rising)

              bracket = [LOG_SMALLEST, LOG_LARGEST]
              u = start(target, df, form).clamp(*bracket)
              STEPS.times do |step|
                following = next_u(u, step, bracket, target, df, form, rising)
                return Math.exp(following) if (following - u).abs <= 1e-14 * [1.0, u.abs].max

                u = following
              end
              Math.exp(bracket.sum / 2.0)
            end

            # Still short of the target at the largest Float.
            def beyond?(target, df, form, rising)
              gap, = gap(LOG_LARGEST, df, form, target)
              !gap.zero? && gap.positive? != rising
            end

            # Newton's next log t, narrowing the bracket; its middle when the
            # step leaves it, or after BISECT_AFTER steps. The solver's state is
            # passed rather than held.
            def next_u(u, step, bracket, target, df, form, rising) # rubocop:disable Metrics/ParameterLists
              gap, slope = gap(u, df, form, target)
              return u if gap.zero?

              bracket[gap.positive? == rising ? 1 : 0] = u
              newton = u - (gap / slope)
              inside = step < BISECT_AFTER && newton > bracket.first && newton < bracket.last
              inside ? newton : bracket.sum / 2.0
            end

            # [log F(u) - target, its slope in u].
            def gap(u, df, form, target)
              tails, middle, log_w = StudentTails.logs(u, df)
              return [middle - target, 2.0 * Math.exp(log_w - middle)] if form == :middle

              [tails - target, -2.0 * Math.exp(log_w - tails)]
            end

            # A start at or below the root. The middle: the density is largest
            # at 0, so t is at least P(|T| < t) over twice it. The tails: t is
            # at least the normal quantile, and at least where
            # x**a/(a B(a, 1/2)) alone reaches q.
            def start(target, df, form)
              log_beta = StudentTails.log_beta_half(df / 2.0)
              return target - StudentTails::LOG_TWO + (0.5 * Math.log(df)) + log_beta if form == :middle

              [Math.log(-Normal.quantile(Math.exp(target) / 2.0)), heavy_start(target, df, log_beta)].compact.max
            end

            # Where x**a/(a B(a, 1/2)) alone reaches q, when that x is below 1.
            def heavy_start(target, df, log_beta)
              log_x = (target + Math.log(df / 2.0) + log_beta) / (df / 2.0)
              0.5 * (Math.log(df) + StudentTails.log_one_minus(log_x) - log_x) if log_x.negative?
            end
          end
        end
        private_constant :StudentT

        # Student's t's two probabilities, read in logs from log t. For t >= 0,
        # with r = t**2/df, x = 1/(1 + r) and y = r/(1 + r), the tails
        # P(|T| > t) = I_x(df/2, 1/2) and the middle P(|T| < t) =
        # I_y(1/2, df/2). The continued fraction gives whichever converges
        # there and the other is its complement, so a small one keeps its
        # digits. Below SMALL_SHAPE the middle comes from expm1 of I_x's
        # series instead, since 1 - I_x would cancel.
        module StudentTails
          SMALL_SHAPE = 0.05
          LARGE_SHAPE = 20
          SERIES_TERMS = 200
          HALF_LOG_PI = 0.5 * Math.log(Math::PI)
          LOG_TWO = Math.log(2)
          # Dirichlet's eta(k) = (1 - 2**(1 - k)) zeta(k), for k from 1 to 40.
          ETA = [0.6931471805599453, 0.8224670334241132, 0.9015426773696957, 0.9470328294972459,
                 0.9721197704469093, 0.9855510912974351, 0.9925938199228302, 0.9962330018526478,
                 0.9980942975416053, 0.9990395075982715, 0.9995171434980608, 0.9997576851438582,
                 0.9998785427632652, 0.9999391703459797, 0.9999695512130993, 0.9999847642149061,
                 0.999992378292041, 0.9999961878696101, 0.9999980935081717, 0.9999990466115816,
                 0.9999995232582155, 0.9999997616132308, 0.9999998808013184, 0.9999999403988924,
                 0.999999970198857, 0.999999985099232, 0.9999999925495505, 0.9999999962747534,
                 0.9999999981373694, 0.9999999990686823, 0.9999999995343404, 0.9999999997671699,
                 0.9999999998835849, 0.9999999999417925, 0.9999999999708962, 0.9999999999854481,
                 0.999999999992724, 0.999999999996362, 0.999999999998181, 0.9999999999990905].freeze
          # log Gamma(a + 1/2) - log Gamma(a) = log(a)/2 + (1/a) * sum c_j / a**(2j), from the
          # Stirling series with Bernoulli polynomials; below 2e-19 from LARGE_SHAPE.
          GAMMA_RATIO = [-1 / 8r, 1 / 192r, -1 / 640r, 17 / 14_336r, -31 / 18_432r, 2073 / 540_672r]
                        .map(&:to_f).freeze

          class << self
            # [log P(|T| > t), log P(|T| < t), log w] at log t = u, where
            # w = x**a y**(1/2) / B(a, 1/2) and d P(|T| < t) / du = 2w.
            def logs(u, df)
              a = df / 2.0
              log_r = (2.0 * u) - Math.log(df)
              log_x = -log_one_plus_exp(log_r)
              log_w = weight(a, log_r, log_x)
              return middle_first(log_w, Math.exp(log_r + log_x), a) unless log_r > Math.log(1.5 / (a + 1.0))

              tails = tails_first(log_w, log_x, a)
              [tails, log_one_minus(tails), log_w]
            end

            # log B(a, 1/2).
            def log_beta_half(a)
              return log_a_beta_small(a) - Math.log(a) if a < SMALL_SHAPE
              return HALF_LOG_PI - gamma_ratio(a) if a >= LARGE_SHAPE

              Math.lgamma(a).first + HALF_LOG_PI - Math.lgamma(a + 0.5).first
            end

            # log(1 - e**z) for z <= 0.
            def log_one_minus(z)
              z > -LOG_TWO ? Math.log(-Precise.expm1(z)) : Precise.log1p(-Math.exp(z))
            end

            private

            # log w = a log x + log(y)/2 - log B(a, 1/2), log y being log r + log x.
            def weight(a, log_r, log_x) = (a * log_x) + (0.5 * (log_r + log_x)) - log_beta_half(a)

            # log(1 + e**v), so log x is read from log r without forming r.
            def log_one_plus_exp(value)
              value.positive? ? value + Precise.log1p(Math.exp(-value)) : Precise.log1p(Math.exp(value))
            end

            # Where the fraction runs in y: the middle first, the tails its complement.
            def middle_first(log_w, y, a)
              middle = LOG_TWO + log_w - Math.log(Beta.fraction(y, 0.5, a))
              [log_one_minus(middle), middle, log_w]
            end

            # Where the fraction runs in x: log P(|T| > t).
            def tails_first(log_w, log_x, a)
              x = Math.exp(log_x)
              return series_log_tails(x, log_x, a) if a < SMALL_SHAPE

              log_w - Math.log(a) - Math.log(Beta.fraction(x, a, 0.5))
            end

            # log I_x(a, 1/2) = a log x + log(sum) - log(a B(a, 1/2)) for small a,
            # the sum that of the hypergeometric series 2F1(a, 1/2; a + 1; x),
            # which converges as x**n, x below 0.43 where it is used.
            def series_log_tails(x, log_x, a)
              sum = 0.0
              coefficient = 1.0
              power = 1.0
              (1..SERIES_TERMS).each do |n|
                coefficient *= (n - 0.5) / n
                power *= x
                term = coefficient * a / (a + n) * power
                sum += term
                break if term <= 1e-17 * sum
              end
              (a * log_x) + Precise.log1p(sum) - log_a_beta_small(a)
            end

            # log(a B(a, 1/2)) = -sum eta(k) (-2a)**k / k, for a below SMALL_SHAPE.
            def log_a_beta_small(a)
              power = 1.0
              ETA.each_with_index.sum do |eta, index|
                power *= -2.0 * a
                eta * power / (index + 1)
              end * -1.0
            end

            def gamma_ratio(a)
              square = 1.0 / (a * a)
              (0.5 * Math.log(a)) + (GAMMA_RATIO.reverse.reduce { |sum, coefficient| (sum * square) + coefficient } / a)
            end
          end
        end
        private_constant :StudentTails
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
