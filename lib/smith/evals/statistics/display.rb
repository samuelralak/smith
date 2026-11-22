# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # Smith's rounding for display (design 7.6), so a screen never does
      # arithmetic. Percents to whole numbers, differences in percentage
      # points to one decimal and signed, scores to two. Rounding is half away
      # from zero on the decimal value: the stored double's shortest
      # round-trip spelling (Float#to_s), read exactly as a Rational, scaled
      # and rounded, so 0.725 shows "73" though its double is slightly below.
      # A value that is not exactly 0 or 1 never shows as the end of the scale,
      # and a bound that decides a verdict never rounds onto its threshold:
      # decimals are added, up to three. Frozen with slice 1a.1.
      module Display
        SCALE = { "percent" => 100, "points" => 100, "score" => 1 }.freeze
        START = { "percent" => 0, "points" => 1, "score" => 2 }.freeze
        MAX_DECIMALS = 3

        class << self
          # One value as text, rounded half away from zero; nil stays nil.
          def text(value, unit:, decimals:, signed: false)
            return if value.nil?

            spelled(rounded(value, SCALE.fetch(unit) * (10**decimals)), decimals, signed)
          end

          # An estimate's point and bounds, never pinned at the end of the
          # scale unless exactly there: decimals are added for all three, up
          # to three, and a value still pinned is rounded toward the inside.
          def estimate(point:, lower:, upper:, unit:)
            return { "unit" => unit, "decimals" => 0, "point" => nil, "lower" => nil, "upper" => nil } if point.nil?

            decimals = START.fetch(unit)
            decimals += 1 while decimals < MAX_DECIMALS && [point, lower, upper].any? { pinned?(_1, unit, decimals) }
            { "unit" => unit, "decimals" => decimals, "point" => inside(point, unit, decimals),
              "lower" => inside(lower, unit, decimals), "upper" => inside(upper, unit, decimals) }
          end

          # A difference ({"point", "lower", "upper"}), signed. A bound that
          # decides the verdict (the lower bound of "better", the upper of
          # "worse") that would round onto its threshold gets decimals added,
          # up to three.
          def difference(bounds, verdict:, margin:, unit:)
            decimals = START.fetch(unit)
            decimals += 1 while decimals < MAX_DECIMALS && onto_threshold?(bounds, verdict, margin, unit, decimals)
            { "unit" => unit, "decimals" => decimals,
              **%w[point lower upper].to_h { |name| [name, text(bounds[name], unit:, decimals:, signed: true)] } }
          end

          # A size helper's low, typical and high: points as whole numbers,
          # counts as they are.
          def range(values, unit:)
            texts = values.transform_values { |value| unit == "count" ? value.to_s : text(value, unit:, decimals: 0) }
            { "unit" => unit, "decimals" => 0, **texts }
          end

          private

          def exact(value)
            value.is_a?(Float) ? Rational(value.to_s) : Rational(value)
          end

          def rounded(value, factor)
            (exact(value) * factor).round(half: :up)
          end

          def spelled(number, decimals, signed)
            magnitude = number.abs
            digits = magnitude.to_s
            unless decimals.zero?
              unit = 10**decimals
              digits = "#{magnitude / unit}.#{(magnitude % unit).to_s.rjust(decimals, "0")}"
            end
            return digits if magnitude.zero?
            return "-#{digits}" if number.negative?

            signed ? "+#{digits}" : digits
          end

          # Strictly between 0 and 1 but shown as the end of the scale.
          def pinned?(value, unit, decimals)
            return false if value.nil? || value <= 0 || value >= 1

            whole = SCALE.fetch(unit) * (10**decimals)
            [0, whole].include?(rounded(value, whole))
          end

          def inside(value, unit, decimals)
            return text(value, unit:, decimals:) unless pinned?(value, unit, decimals)

            whole = SCALE.fetch(unit) * (10**decimals)
            scaled = exact(value) * whole
            spelled(scaled * 2 > whole ? scaled.floor : scaled.ceil, decimals, false)
          end

          def onto_threshold?(bounds, verdict, margin, unit, decimals)
            whole = SCALE.fetch(unit) * (10**decimals)
            case verdict
            when "better" then rounded(bounds["lower"], whole) <= rounded(margin, whole)
            when "worse" then rounded(bounds["upper"], whole) >= 0
            else false
            end
          end
        end
      end
    end
  end
end
