# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (p, n, a, b, c, d, k, x, y)

module Smith
  module Evals
    module Statistics
      module Formulas
        # Chance-corrected agreement (design 7.8).
        module Agreement
          # Cohen's kappa for pairs of two raters' labels; nil when chance
          # agreement is 1 (no variation).
          def cohen_kappa(pairs)
            raise ArgumentError, "cohen_kappa needs at least one pair" if pairs.empty?

            observed = pairs.count { |first, second| first == second }.fdiv(pairs.size)
            expected = chance_agreement(pairs)
            return if expected == 1

            (observed - expected) / (1 - expected)
          end

          # Krippendorff's alpha, nominal, from the coincidence matrix. Each
          # unit lists the values it was given (nil for a missing one); units
          # with fewer than two values are left out. nil when no two values
          # differ anywhere.
          def krippendorff_alpha(units)
            matrix = coincidences(units)
            totals = Hash.new(0.0)
            matrix.each { |(value, _), weight| totals[value] += weight }
            expected = expected_disagreement(totals)
            return if expected.zero?

            1 - ((totals.values.sum - 1) * disagreement(matrix) / expected)
          end

          private

          # sum over c != k of n_c n_k.
          def expected_disagreement(totals)
            totals.sum { |first, a| totals.sum { |second, b| first == second ? 0.0 : a * b } }
          end

          # sum over c != k of o_ck.
          def disagreement(matrix)
            matrix.sum { |(first, second), weight| first == second ? 0.0 : weight }
          end

          def chance_agreement(pairs)
            seconds = pairs.map(&:last).tally
            pairs.map(&:first).tally.sum do |label, count|
              count.fdiv(pairs.size) * seconds.fetch(label, 0).fdiv(pairs.size)
            end
          end

          # o_ck = sum over units of (pairs c, k in the unit) / (m_u - 1).
          def coincidences(units)
            matrix = Hash.new(0.0)
            units.each do |unit|
              values = unit.compact
              next if values.size < 2

              counts = values.tally
              counts.each do |first, a|
                counts.each do |second, b|
                  matrix[[first, second]] += pairs_of(first, a, second, b).fdiv(values.size - 1)
                end
              end
            end
            matrix
          end

          def pairs_of(first, a, second, b) = first == second ? a * (a - 1) : a * b
        end
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
