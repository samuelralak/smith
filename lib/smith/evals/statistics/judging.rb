# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # judge_check (design 7.8).
      module Judging
        READINGS = %w[with_confidence on_point].freeze
        RATES = %w[catches_failures passes_good].freeze
        BAR_SHAPE = "bar is nil or { catches_failures:, passes_good: }, each nil or a rate in 0..1"

        # The interface's keywords are frozen (design 7.1).
        # A judge's two rates against labels, each read against the bar.
        def judge_check(caught:, failures:, passed:, good:, bar: nil, gates_on: :with_confidence, confidence: 0.95)
          bar = Judging.bar!(bar)
          gates_on = gates_on.to_s
          raise ArgumentError, "gates_on is :with_confidence or :on_point" unless READINGS.include?(gates_on)

          rates = { "catches_failures" => rate(successes: caught, total: failures, confidence:),
                    "passes_good" => rate(successes: passed, total: good, confidence:) }
          JudgeCheck.new(catches_failures: rates["catches_failures"], passes_good: rates["passes_good"], bar:,
                         meets_bar: bar && rates.to_h { |name, estimate| [name, Judging.reading(estimate, bar[name])] },
                         gates_on:)
        end

        class << self
          # The declared minimum rates, each nil (no bar) or in 0..1.
          def bar!(value)
            return if value.nil?

            bar = named(value)
            RATES.to_h { |name| [name, bar[name]&.to_f] }
          end

          # Both readings of one rate against its minimum: on the point, and
          # with confidence (the lower bound reaches it). No minimum is met;
          # no data meets none.
          def reading(estimate, minimum)
            return { "on_point" => true, "with_confidence" => true } if minimum.nil?
            return { "on_point" => false, "with_confidence" => false } if estimate.point.nil?

            { "on_point" => estimate.point >= minimum, "with_confidence" => estimate.lower >= minimum }
          end

          private

          def named(value)
            bar = value.transform_keys(&:to_s) if value.is_a?(Hash)
            return bar if bar && fits?(bar)

            raise ArgumentError, BAR_SHAPE
          end

          def fits?(bar)
            (bar.keys - RATES).empty? && bar.values.all? { |rate| rate.nil? || rate?(rate) }
          end

          def rate?(value) = Inputs.real?(value) && value.between?(0, 1)
        end
      end
      private_constant :Judging
    end
  end
end
