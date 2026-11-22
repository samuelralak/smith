# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # One estimate over checked, sorted samples (design 7.3).
      class Estimator
        include Resampling

        WHOLE_LINE = [-Float::INFINITY, Float::INFINITY].freeze

        def initialize(samples, request)
          @samples = samples
          @request = request
          @reducer = request.reducer
          @digest = InputsDigest.call("estimate", options, samples)
        end

        def call
          return finish(empty) if @samples.empty?

          @values = @samples.map { |sample| @reducer.value(sample.trials) }
          @warnings = opening_warnings
          interval = @reducer.bootstrap? ? bootstrap : closed_form
          finish({ n:, point:, successes:, warnings: @warnings }.merge(interval))
        end

        private

        # A seed changes only a bootstrap, so only a bootstrap's digest holds one.
        def options
          options = { "reducer" => @reducer.name, "confidence" => @request.confidence,
                      "resamples" => @request.resamples, "small_sample_threshold" => @request.threshold,
                      "scale" => @request.scale }
          @request.seed && @reducer.bootstrap? ? options.merge("seed" => @request.seed) : options
        end

        def n = @samples.size
        def point = @point ||= @values.sum.fdiv(n)
        def level = @request.confidence
        def keys = @samples.map { |sample| SampleList.cluster_key(sample) }
        def successes = @reducer.binary? ? @values.sum : @values.sum.to_f
        def unit = @request.scale == "binary" ? "percent" : "score"

        def opening_warnings
          warnings = []
          warnings << "uneven_trials" if @samples.map { |sample| sample.trials.size }.uniq.size > 1
          warnings << "small_sample" if n < @request.threshold
          warnings
        end

        def empty
          { method_name: @reducer.binary? ? "wilson" : "t", n: 0, point: nil, lower: nil, upper: nil, successes: nil,
            warnings: ["no_samples"] }
        end

        def closed_form
          @point = @values.first.to_f if equal?
          deff, clusters, applies = Formulas.design_effect(@values, keys)
          clustering(deff, clusters, applies).merge(interval_at(n / deff))
        end

        def clustering(deff, clusters, applies)
          return {} unless applies

          @warnings << "few_clusters" if clusters < 30
          { clusters:, design_effect: deff, n_effective: n / deff }
        end

        def interval_at(effective)
          return wilson(effective) if @reducer.binary?

          @request.scale == "binary" ? binary_mean(effective) : continuous(effective)
        end

        def wilson(effective)
          lower, upper = Formulas.wilson(p: point, n: effective, level:)
          { method_name: "wilson", lower:, upper: }
        end

        # A mean of pass/fail trials: the beta posterior below 30 samples or
        # with no variation, t at 30 or more.
        def binary_mean(effective)
          return clipped_t(sample_sd, effective) unless n < 30 || equal?

          @warnings << "no_variation" if equal? && n >= 30
          lower, upper = Formulas.beta_posterior(successes: point * effective, n: effective, level:, point:)
          { method_name: "beta_posterior", lower:, upper: }
        end

        def continuous(effective)
          return { method_name: "t", lower: nil, upper: nil, approximate: true } if n < 2

          @warnings << "no_variation" if equal?
          clipped_t(sample_sd, effective).merge(approximate: n < 30)
        end

        # t on the effective size, cut to 0..1. An effective size of 1 or
        # less leaves t no degrees of freedom: the interval is then the
        # whole scale, the limit of t as its degrees of freedom fall to 0.
        # Just above 1, t passes the largest Float and gives the same.
        def clipped_t(spread, effective)
          lower, upper = effective > 1 ? Formulas.t_interval(mean: point, sd: spread, n: effective, level:) : WHOLE_LINE
          @warnings << "interval_clipped" if lower.negative? || upper > 1
          { method_name: "t", lower: [0.0, lower].max, upper: [1.0, upper].min }
        end

        # Every value equal, decided exactly (a mean's values as Rationals),
        # never by a spread that rounding left above zero.
        def equal?
          return @equal unless @equal.nil?

          exact = @reducer.kind == :mean ? @samples.lazy.map { |sample| @reducer.exact(sample.trials) } : @values
          @equal = Formulas.equal_values?(exact)
        end

        def sample_sd
          return 0.0 if n < 2 || equal?

          Math.sqrt(@values.sum { |value| (value - point)**2 } / (n - 1))
        end

        def finish(fields)
          fields = { measure: @reducer.binary? ? "pass_rate" : "mean", reducer: @reducer.name, method_revision: 1,
                     confidence: level, basis: "samples", clusters: nil, design_effect: nil, n_effective: nil,
                     approximate: false, inputs_digest: @digest, seed: nil }.merge(fields)
          Estimate.new(**fields, display: Display.estimate(**fields.slice(:point, :lower, :upper), unit:))
        end
      end
      private_constant :Estimator
    end
  end
end
