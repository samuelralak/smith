# frozen_string_literal: true

module Smith
  module Budget
    # What a provider request may spend (the hold a host's budget ledger is
    # asked to admit) or did spend (what it is reconciled with): its input
    # tokens (uncached, cache reads and cache writes together), its output
    # tokens (thinking included), and its cost from the pricing catalog, nil
    # when the model has no price there.
    Amount = Data.define(:input_tokens, :output_tokens, :cost) do
      def initialize(input_tokens:, output_tokens:, cost:)
        unless [input_tokens, output_tokens].all? { _1.is_a?(Integer) && !_1.negative? }
          raise ArgumentError, "a budget amount's token counts must be non-negative Integers"
        end
        unless cost.nil? || (cost.is_a?(Numeric) && cost.finite? && !cost.negative?)
          raise ArgumentError, "a budget amount's cost must be nil or a non-negative number"
        end

        super
      end

      def tokens = input_tokens + output_tokens
    end
  end
end
