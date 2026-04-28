# frozen_string_literal: true

module Smith
  module Pricing
    # Compute provider cost for a single agent call. Two pricing shapes
    # are supported:
    #
    #   Flat (existing): the catalog entry is a Hash with
    #     `:input_cost_per_token` / `:output_cost_per_token` keys. Used
    #     for models with a single rate across all input sizes
    #     (Gemini 2.5 Flash, Claude Opus 4.6/4.7).
    #
    #   Tiered (new): the catalog entry has a `:tiers` array of bracket
    #     hashes, each with `:max_input_tokens` (nil = unbounded ceiling),
    #     `:input_cost_per_token`, `:output_cost_per_token`. Tiers are
    #     walked in order; the first whose `max_input_tokens` covers the
    #     call's input_tokens picks the rate. Used for models with
    #     long-context premium pricing (Gemini 2.5 Pro: $1.25/$10 below
    #     200K input tokens, $2.50/$15 above).
    def self.compute_cost(model:, input_tokens:, output_tokens:)
      catalog = Smith.config.pricing
      return nil unless catalog

      entry = catalog[model.to_s]
      return nil unless entry

      rates = resolve_rates(entry, input_tokens)
      return nil unless rates

      input_rate, output_rate = rates
      (input_tokens * input_rate) + (output_tokens * output_rate)
    end

    # Returns [input_rate, output_rate] or nil if no applicable rate.
    # Tiered shape is recognized by the presence of a :tiers key; flat
    # shape is the legacy default.
    def self.resolve_rates(entry, input_tokens)
      tiers = entry[:tiers] || entry["tiers"]
      if tiers.is_a?(Array) && !tiers.empty?
        resolve_tiered(tiers, input_tokens)
      else
        flat = [entry[:input_cost_per_token], entry[:output_cost_per_token]]
        return nil unless flat.all? { |r| r.is_a?(Numeric) }

        flat
      end
    end
    private_class_method :resolve_rates

    def self.resolve_tiered(tiers, input_tokens)
      tier = tiers.find do |t|
        max = t[:max_input_tokens] || t["max_input_tokens"]
        max.nil? || input_tokens <= max
      end
      return nil unless tier

      input_rate = tier[:input_cost_per_token] || tier["input_cost_per_token"]
      output_rate = tier[:output_cost_per_token] || tier["output_cost_per_token"]
      return nil unless input_rate.is_a?(Numeric) && output_rate.is_a?(Numeric)

      [input_rate, output_rate]
    end
    private_class_method :resolve_tiered
  end
end
