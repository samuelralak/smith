# frozen_string_literal: true

require_relative "formulas/intervals"
require_relative "formulas/clusters"
require_relative "formulas/estimators"
require_relative "formulas/paired"
require_relative "formulas/readings"
require_relative "formulas/sizes"
require_relative "formulas/agreement"

module Smith
  module Evals
    module Statistics
      # The formulas: plain functions on plain numbers, each tested against
      # the reference fixture (design 7.2 to 7.8). The interface picks among
      # them; a host reads its results, not these. Experimental until slice 6.
      #
      # O(n) time and O(1) extra space in their inputs except: percentiles
      # O(n log n); the design effect O(n) time and O(n) space (its index
      # lists by cluster); the cluster bootstrap O(B (K + n)) time and
      # O(B + n) space for B resamples; the p-value bisection 100 interval
      # evaluations; Holm O(m log m); Krippendorff's alpha
      # O(sum_u m_u**2 + K**2); McNemar's exact sum O(min(b, c)).
      module Formulas
        extend Intervals
        extend Clusters
        extend Estimators
        extend Paired
        extend Readings
        extend Sizes
        extend Agreement
      end
    end
  end
end
