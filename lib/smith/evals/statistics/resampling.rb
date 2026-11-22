# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # An estimate's cluster-aware percentile bootstrap (design 7.2), for
      # pass@k and pass^k; mixed into Estimator, whose samples, values and
      # warnings it reads.
      module Resampling
        private

        def bootstrap
          clusters = keys.uniq.size
          return too_few_units(clusters) if clusters < 2

          seed = @request.seed || @digest[7, 16]
          lower, upper = Formulas.cluster_bootstrap(values: @values, keys:, resamples: @request.resamples,
                                                    seed: seed.to_i(16), level:)
          { method_name: "bootstrap", lower:, upper:, clusters: shared(clusters), approximate: n < 200, seed: }
        end

        # Resampling one cluster, or one sample, redraws the same data every
        # time and measures nothing: the bootstrap is not run, and the
        # interval is the whole scale, never zero wide.
        def too_few_units(clusters)
          shared = shared(clusters)
          @warnings.push("interval_clipped", "too_few_units")
          { method_name: "bootstrap", lower: 0.0, upper: 1.0, clusters: shared, approximate: n < 200, seed: nil }
        end

        # The bootstrap's cluster count when samples share clusters (else
        # nil), with few_clusters below 30.
        def shared(clusters)
          return unless clusters < n

          @warnings << "few_clusters" if clusters < 30
          clusters
        end
      end
      private_constant :Resampling
    end
  end
end
