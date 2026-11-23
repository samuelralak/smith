# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # estimate and rate.
      module Estimation
        # The interface's keywords are frozen (design 7.1).
        # One reducer's value over samples, with the interval design 7.3 chooses.
        def estimate(samples:, reducer:, scale: :binary, confidence: 0.95, resamples: RESAMPLES,
                     small_sample_threshold: 30, seed: nil)
          kind = Inputs.reducer!(reducer)
          request = Request.new(reducer: kind, scale: Inputs.scale!(scale, kind),
                                confidence: Inputs.confidence!(confidence),
                                resamples: Inputs.count!(resamples, "resamples", minimum: MIN_RESAMPLES),
                                threshold: Inputs.count!(small_sample_threshold, "small_sample_threshold"),
                                seed: Inputs.seed!(seed))
          counted = SampleList.check!(samples, "samples", reducer: kind, scale: request.scale)
          SampleList.bootstrap_work!(counted.size, request.resamples) if kind.bootstrap?
          Estimator.new(counted, request).call
        end

        # Wilson on counts that are not samples: a judge's catch rate.
        def rate(successes:, total:, confidence: 0.95)
          total = Inputs.count!(total, "total", minimum: 0)
          successes = Inputs.count!(successes, "successes", minimum: 0)
          raise ArgumentError, "successes are at most the total" if successes > total

          Estimation.counted(successes, total, Inputs.confidence!(confidence))
        end

        class << self
          def counted(successes, total, level)
            point = total.zero? ? nil : successes.fdiv(total)
            lower, upper = Formulas.wilson(p: point, n: total, level:)
            Estimate.new(measure: "rate", reducer: nil, method_name: "wilson", method_revision: 1, confidence: level,
                         basis: "counts", n: total, successes:, clusters: nil, design_effect: nil, n_effective: nil,
                         point:, lower:, upper:, approximate: false, warnings: warnings(total),
                         display: Display.estimate(point:, lower:, upper:, unit: "percent"),
                         inputs_digest: digest(successes, total, level), seed: nil)
          end

          private

          def warnings(total)
            return ["no_samples"] if total.zero?

            total < 30 ? ["small_sample"] : []
          end

          def digest(successes, total, level)
            InputsDigest.call("rate", { "confidence" => level, "small_sample_threshold" => 30 },
                              { "successes" => successes, "total" => total })
          end
        end
      end
      private_constant :Estimation
    end
  end
end
