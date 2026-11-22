# frozen_string_literal: true

require_relative "../../error"

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (x, a, b, df)

module Smith
  module Evals
    module Statistics
      # The distribution functions the formulas read (design 7.2): the normal
      # quantile, the regularized incomplete beta and its quantile (Beta),
      # and t's quantile and distribution function (StudentT). Plain
      # functions on Floats, each bounded: a fixed number of operations, or
      # at most 2,000 (incomplete beta), 400 (beta quantile) or 200 (t
      # quantile) iterations. Experimental until slice 6.
      module Distributions
        # Wichura (1988), Algorithm AS 241 (PPND16), Applied Statistics
        # 37(3):477-484; coefficients from the paper, lowest power first.
        module Normal
          NEAR = [3.387132872796366608e0, 1.3314166789178437745e+2, 1.9715909503065514427e+3,
                  1.3731693765509461125e+4, 4.5921953931549871457e+4, 6.7265770927008700853e+4,
                  3.3430575583588128105e+4, 2.5090809287301226727e+3].freeze
          NEAR_DIVISOR = [1.0, 4.2313330701600911252e+1, 6.8718700749205790830e+2, 5.3941960214247511077e+3,
                          2.1213794301586595867e+4, 3.9307895800092710610e+4, 2.8729085735721942674e+4,
                          5.2264952788528545610e+3].freeze
          MIDDLE = [1.42343711074968357734e0, 4.63033784615654529590e0, 5.76949722146069140550e0,
                    3.64784832476320460504e0, 1.27045825245236838258e0, 2.41780725177450611770e-1,
                    2.27238449892691845833e-2, 7.74545014278341407640e-4].freeze
          MIDDLE_DIVISOR = [1.0, 2.05319162663775882187e0, 1.67638483018380384940e0, 6.89767334985100004550e-1,
                            1.48103976427480074590e-1, 1.51986665636164571966e-2, 5.47593808499534494600e-4,
                            1.05075007164441684324e-9].freeze
          FAR = [6.65790464350110377720e0, 5.46378491116411436990e0, 1.78482653991729133580e0,
                 2.96560571828504891230e-1, 2.65321895265761230930e-2, 1.24266094738807843860e-3,
                 2.71155556874348757815e-5, 2.01033439929228813265e-7].freeze
          FAR_DIVISOR = [1.0, 5.99832206555887937690e-1, 1.36929880922735805310e-1, 1.48753612908506148525e-2,
                         7.86869131145613259100e-4, 1.84631831751005468180e-5, 1.42151175831644588870e-7,
                         2.04426310338993978564e-15].freeze

          def self.quantile(prob)
            centred = prob - 0.5
            return centred * ratio(NEAR, NEAR_DIVISOR, 0.180625 - (centred * centred)) if centred.abs <= 0.425

            value = tail(Math.sqrt(-Math.log(centred.negative? ? prob : 1 - prob)))
            centred.negative? ? -value : value
          end

          def self.tail(distance)
            distance <= 5 ? ratio(MIDDLE, MIDDLE_DIVISOR, distance - 1.6) : ratio(FAR, FAR_DIVISOR, distance - 5)
          end

          # Horner's rule from the highest power, as the paper evaluates it.
          def self.ratio(top, bottom, at)
            top.reverse.reduce { |sum, c| (sum * at) + c } / bottom.reverse.reduce { |sum, c| (sum * at) + c }
          end
        end
        private_constant :Normal

        # log(1 + v) and e**v - 1 to a few ulps, by Kahan's forms. Math has
        # neither before Ruby 3.5, and one rule on every Ruby keeps the bytes
        # the same everywhere.
        module Precise
          def self.log1p(value)
            sum = 1.0 + value
            return Math.log(sum) if value.abs >= 1

            shifted = sum - 1.0
            shifted.zero? ? value : Math.log(sum) * value / shifted
          end

          def self.expm1(value)
            return Math.exp(value) - 1.0 if value.abs >= 1

            power = Math.exp(value)
            shifted = power - 1.0
            return value if shifted.zero?
            return shifted if (shifted + 1.0).zero?

            shifted * value / Math.log(power)
          end
        end
        private_constant :Precise

        class << self
          # The standard normal quantile, for 0 < p < 1; 0.5 gives exactly 0.
          def normal_quantile(prob)
            probability!(prob, "normal_quantile's p")
            Normal.quantile(prob.to_f)
          end

          # I_x(a, b) for x in 0..1 and a, b > 0; x = 0 gives 0, x = 1 gives 1.
          def incomplete_beta(x, a, b)
            raise ArgumentError, "incomplete_beta's x is in 0..1" unless real?(x) && x.between?(0, 1)

            shape!(a, b)
            Beta.regularized(x.to_f, a.to_f, b.to_f)
          end

          # The x with I_x(a, b) = q, for q in 0..1; q = 0 gives 0, q = 1 gives 1.
          def beta_quantile(target, a, b)
            raise ArgumentError, "beta_quantile's q is in 0..1" unless real?(target) && target.between?(0, 1)

            shape!(a, b)
            return 0.0 if target.zero?
            return 1.0 if target == 1

            BetaQuantile.call(target.to_f, a.to_f, b.to_f)
          end

          # t's quantile for 0 < p < 1 and a real df > 0 (an effective size
          # gives a fractional one), within 1e-10 relative everywhere;
          # Float::INFINITY when it passes the largest Float. p = 0.5 gives
          # exactly 0.
          def t_quantile(prob, df)
            probability!(prob, "t_quantile's p")
            degrees!(df)
            StudentT.quantile(prob.to_f, df.to_f)
          end

          # P(T <= t) for t's distribution with df > 0 degrees of freedom.
          def t_cdf(value, df)
            1.0 - t_sf(value, df)
          end

          # P(T > t), the upper tail, read directly so a small p-value keeps
          # its digits; t_cdf is its complement.
          def t_sf(value, df)
            raise ArgumentError, "t's value is a finite number" unless real?(value)

            degrees!(df)
            StudentT.upper(value.to_f, df.to_f)
          end

          private

          def real?(value)
            value.is_a?(Numeric) && value.real? && value.to_f.finite?
          end

          def probability!(prob, name)
            raise ArgumentError, "#{name} is strictly between 0 and 1" unless real?(prob) && prob.positive? && prob < 1
          end

          def shape!(a, b)
            return if real?(a) && real?(b) && a.positive? && b.positive?

            raise ArgumentError, "the beta shapes a and b are positive numbers"
          end

          def degrees!(df)
            raise ArgumentError, "t's degrees of freedom are a positive number" unless real?(df) && df.positive?
          end
        end
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
