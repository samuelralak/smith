# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # detectable and required_samples (design 7.7): one shape, low,
      # typical and high over the correlations in CORRELATIONS.
      module Sizing
        # rubocop:disable Naming/MethodParameterName -- the interface's keyword is n (design 7.1)
        # The smallest change n samples can detect, either way.
        def detectable(n:, baseline:, paired: true, power: 0.8, confidence: 0.95)
          Inputs.count!(n, "n")
          setting = Sizing.setting(baseline, paired, power, confidence)
          # The larger of the smallest increase and decrease, over the
          # directions where a change is detectable; nil where neither is.
          smallest = CORRELATIONS.transform_values do |rho|
            %i[increase decrease].filter_map { |direction| Sizing.smallest(n, setting, paired && rho, direction) }.max
          end
          Detectable.new(method_name: "normal_approximation", method_revision: 1, n:, **setting.except(:alpha),
                         direction: "either", smallest_difference: smallest, assumptions: Sizing.assumptions(paired),
                         display: Display.range(smallest, unit: "points"))
        end
        # rubocop:enable Naming/MethodParameterName

        def required_samples(baseline:, difference:, paired: true, power: 0.8, confidence: 0.95)
          setting = Sizing.setting(baseline, paired, power, confidence)
          difference = Sizing.difference!(setting[:baseline], difference)
          samples = CORRELATIONS.transform_values { |rho| Sizing.size(setting, difference, paired && rho) }
          RequiredSamples.new(method_name: "normal_approximation", method_revision: 1, difference:,
                              **setting.except(:alpha), samples:, assumptions: Sizing.assumptions(paired),
                              display: Display.range(samples, unit: "count"))
        end

        class << self
          # The checked inputs as Floats, and alpha.
          def setting(baseline, paired, power, confidence)
            raise ArgumentError, "paired is true or false" unless [true, false].include?(paired)

            { baseline: Inputs.level!(baseline, "baseline"), paired:, power: Inputs.level!(power, "power"),
              confidence: Inputs.confidence!(confidence), alpha: 1 - Inputs.confidence!(confidence) }
          end

          def difference!(baseline, difference)
            unless Inputs.real?(difference) && !difference.zero?
              raise ArgumentError, "difference is a number other than 0"
            end

            target = baseline + difference
            return difference.to_f if target.positive? && target < 1

            raise ArgumentError, "baseline + difference is strictly between 0 and 1"
          end

          # The larger of the smallest increase and decrease is the reading;
          # a correlation of false is unpaired.
          def smallest(count, setting, correlation, direction)
            Formulas.smallest_detectable(n: count, baseline: setting[:baseline], correlation: correlation || nil,
                                         direction:, alpha: setting[:alpha], power: setting[:power])
          end

          def size(setting, difference, correlation)
            p1 = setting[:baseline]
            sizes = { p1:, p2: p1 + difference, alpha: setting[:alpha], power: setting[:power] }
            correlation ? Formulas.paired_sample_size(**sizes, correlation:) : Formulas.unpaired_sample_size(**sizes)
          end

          def assumptions(paired) = { "correlation" => paired ? CORRELATIONS : nil }
        end
      end
      private_constant :Sizing
    end
  end
end
