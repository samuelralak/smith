# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (p, n, a, b, c, d, k, x, y)

module Smith
  module Evals
    module Statistics
      module Formulas
        # Sample sizes and the smallest detectable change (design 7.7).
        module Sizes
          BISECTION_STEPS = 200

          # The largest size with one exact spelling in JSON (canonical JSON's
          # integer limit), as a Float bound on the unrounded size.
          LARGEST_SIZE = ((2**53) - 1).to_f

          # Per arm, for two independent runs.
          def unpaired_sample_size(p1:, p2:, alpha: 0.05, power: 0.8)
            whole(unpaired_raw(p1, p2, alpha, power))
          end

          # For one run against another on the same samples.
          def paired_sample_size(p1:, p2:, correlation:, alpha: 0.05, power: 0.8)
            whole(paired_raw(p1, p2, correlation, alpha, power))
          end

          # rubocop:disable Metrics/ParameterLists -- design 7.7's keywords, with alpha and power
          # The smallest change from baseline, up (:increase) or down
          # (:decrease), whose size is at most n; correlation nil is unpaired.
          # nil when no change up to the end of the scale is detectable at n:
          # the edge of the search is never given as an answer. When the
          # bisection never reaches a detectable change, the change the fewest
          # samples detect is found (the size falls with the change, and for
          # paired runs rises again near the end of the scale) and decides.
          def smallest_detectable(n:, baseline:, correlation:, direction:, alpha: 0.05, power: 0.8)
            sign = { increase: 1, decrease: -1 }.fetch(direction) do
              raise ArgumentError, "direction is :increase or :decrease"
            end
            size = ->(change) { raw_size(baseline, baseline + (sign * change), correlation, alpha, power) }
            edge = search_edge(baseline, sign)
            # A baseline nearer that end than the search's smallest change,
            # 1e-9, has no change that way on the scale.
            return if edge.negative?

            found = smallest_within(edge, n, size)
            return found unless found == edge

            best = fewest_samples(edge, size)
            smallest_within(best, n, size) if size.call(best) <= n
          end
          # rubocop:enable Metrics/ParameterLists

          private

          # The largest change the search reads: 1e-9 short of the end of the
          # scale it moves toward.
          def search_edge(baseline, sign) = sign.positive? ? 1 - baseline - 1e-9 : baseline - 1e-9

          # Bisection on [1e-9, high] for the smallest change of size at most
          # n; high itself when no point it reads is.
          def smallest_within(high, n, size)
            low = 1e-9
            BISECTION_STEPS.times do
              middle = (low + high) / 2
              size.call(middle) <= n ? high = middle : low = middle
            end
            high
          end

          # The change in [1e-9, edge] the fewest samples detect, by golden
          # section: the size has one minimum there (at the edge when unpaired).
          def fewest_samples(edge, size)
            low = 1e-9
            high = edge
            ratio = (Math.sqrt(5) - 1) / 2
            BISECTION_STEPS.times do
              left = high - (ratio * (high - low))
              right = low + (ratio * (high - low))
              size.call(left) <= size.call(right) ? high = right : low = left
            end
            [low, high].min_by { |change| size.call(change) }
          end

          # A size past the largest exact integer has no stable spelling (its
          # digits past 2**53 are rounding), so it is refused.
          def whole(raw)
            return raw.ceil if raw <= LARGEST_SIZE

            raise ArgumentError, "a difference this small needs more than 2**53 - 1 samples"
          end

          def raw_size(p1, p2, correlation, alpha, power)
            correlation ? paired_raw(p1, p2, correlation, alpha, power) : unpaired_raw(p1, p2, alpha, power)
          end

          # (z_a sqrt(2 pbar qbar) + z_b sqrt(p1 q1 + p2 q2))**2 / (p1 - p2)**2: a closed
          # form, written as its paper writes it.
          def unpaired_raw(p1, p2, alpha, power) # rubocop:disable Metrics/AbcSize
            pooled = (p1 + p2) / 2
            spread = z_power(power) * Math.sqrt((p1 * (1 - p1)) + (p2 * (1 - p2)))
            (((z_alpha(alpha) * Math.sqrt(2 * pooled * (1 - pooled))) + spread)**2) / ((p1 - p2)**2)
          end

          # (z_a + z_b)**2 (p1 q1 + p2 q2 - 2 rho sqrt(p1 q1 p2 q2)) / (p1 - p2)**2: a
          # closed form, written as its paper writes it.
          def paired_raw(p1, p2, correlation, alpha, power) # rubocop:disable Metrics/AbcSize
            variance = (p1 * (1 - p1)) + (p2 * (1 - p2)) -
                       (2 * correlation * Math.sqrt(p1 * (1 - p1) * p2 * (1 - p2)))
            ((z_alpha(alpha) + z_power(power))**2) * variance / ((p2 - p1)**2)
          end

          def z_alpha(alpha) = Distributions.normal_quantile(1 - (alpha / 2))
          def z_power(power) = Distributions.normal_quantile(power)
        end
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
