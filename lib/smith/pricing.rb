# frozen_string_literal: true

module Smith
  module Pricing
    def self.compute_cost(model:, input_tokens:, output_tokens:)
      catalog = Smith.config.pricing
      return nil unless catalog

      entry = catalog[model.to_s]
      return nil unless entry

      input_rate = entry[:input_cost_per_token]
      output_rate = entry[:output_cost_per_token]
      return nil unless input_rate.is_a?(Numeric) && output_rate.is_a?(Numeric)

      (input_tokens * input_rate) + (output_tokens * output_rate)
    end
  end
end
