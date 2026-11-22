# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName -- the formulas keep their papers' names (p, n, a, b, c, d, k, x, y)

module Smith
  module Evals
    module Statistics
      module Formulas
        # pass@k and pass^k, from n trials with c passing.
        module Estimators
          # 1 - C(n - c, k)/C(n, k), in Chen et al. (2021)'s stable form.
          def pass_at(n:, c:, k:)
            counts!(n, c, k)
            return 1.0 if n - c < k

            1 - ((n - c + 1)..n).reduce(1.0) { |product, i| product * (1 - k.fdiv(i)) }
          end

          # C(c, k)/C(n, k): every one of k trials passes.
          def pass_all(n:, c:, k:)
            counts!(n, c, k)
            return 0.0 if c < k

            (0...k).reduce(1.0) { |product, i| product * (c - i).fdiv(n - i) }
          end

          private

          def counts!(n, c, k)
            return if [n, c, k].all?(Integer) && k.between?(1, n) && c.between?(0, n)

            raise ArgumentError, "pass@k takes Integers with 1 <= k <= n and 0 <= c <= n"
          end
        end
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName
