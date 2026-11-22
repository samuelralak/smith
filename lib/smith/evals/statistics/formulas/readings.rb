# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      module Formulas
        # The p-value a verdict reads, and Holm's correction.
        module Readings
          BISECTION_STEPS = 100

          # The smallest alpha whose interval at level 1 - alpha excludes the
          # reading's threshold (the margin above, zero below); 1 between
          # them. The block gives [lower, upper] at a level. Bisection over
          # [1e-12, 1 - 1e-12], 100 steps. The interval is read at the level
          # 1 - alpha, which holds alpha only to about 1e-16 absolute, so a
          # p-value near the 1e-12 floor keeps about four significant digits.
          def interval_p(point:, margin:)
            return 1.0 if point.between?(0, margin)

            low = 1e-12
            high = 1 - 1e-12
            BISECTION_STEPS.times do
              middle = (low + high) / 2
              lower, upper = yield(1 - middle)
              excluded = point > margin ? lower > margin : upper.negative?
              excluded ? high = middle : low = middle
            end
            high
          end

          # Holm's step-down at alpha: [adjusted p-values, rejected flags],
          # both in the order given.
          def holm(p_values, alpha: 0.05)
            ranks = holm_order(p_values).each_with_index.to_h
            stop = holm_stop(p_values, alpha)
            [holm_adjusted(p_values), p_values.each_index.map { |index| ranks[index] < stop }]
          end

          # max over ranks up to j of min(1, (m - j + 1) p_(j)), in the order given.
          def holm_adjusted(p_values)
            adjusted = Array.new(p_values.size)
            running = 0.0
            holm_order(p_values).each_with_index do |index, rank|
              running = [running, (p_values[index] * (p_values.size - rank)).clamp(..1.0)].max
              adjusted[index] = running
            end
            adjusted
          end

          # The first rank Holm does not reject, or m.
          def holm_stop(p_values, alpha)
            order = holm_order(p_values)
            order.each_index.find { |rank| p_values[order[rank]] > alpha / (p_values.size - rank) } || p_values.size
          end

          # Indexes by p-value, ties in the order given.
          def holm_order(p_values)
            p_values.each_index.sort_by { |index| [p_values[index], index] }
          end
        end
      end
    end
  end
end
