# frozen_string_literal: true

require_relative "pricing/catalog_validation"

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
    #
    # Both shapes accept two optional rates beside input and output:
    # `:cache_read_cost_per_token` and `:cache_write_cost_per_token`, for
    # input read from or written to a prompt cache, which providers report
    # apart from uncached input. An entry may also carry `:batch_discount`,
    # the fraction a provider's batch API takes off (0.5 for half price),
    # applied to the whole cost of a call made in `mode: :batch`. These are
    # configured per catalog: a missing cache rate prices those tokens at 0,
    # and a missing batch discount is 0, so a batch call costs the full
    # rate. Tiers are
    # chosen on the call's total input, uncached plus cache read plus cache
    # write, since that is what long-context premiums are measured against.
    #
    # Catalog keys are normalized once per assigned catalog object:
    #   ["provider", "model"] / [:provider, :model]  -> provider-qualified
    #   "provider/model" (first slash splits)        -> provider-qualified
    #   "model" / :model (no slash)                  -> legacy model-only
    #
    # Lookup policy: a provider-qualified lookup reads only qualified
    # entries and NEVER prices from a legacy model-only rate; unpriced
    # usage stays visibly unpriced (nil cost). A count that is not a
    # non-negative Integer prices as 0. This method never raises,
    # so accounting paths cannot mask a provider error with a pricing
    # configuration error. The legacy-only-key policy is enforced at
    # catalog admission time via `validate_catalog!`.
    # rubocop:disable Metrics/ParameterLists
    def self.compute_cost(model:, input_tokens:, output_tokens:, provider: nil, cache_read_tokens: 0,
                          cache_write_tokens: 0, mode: :sync)
      counts = [input_tokens, output_tokens, cache_read_tokens, cache_write_tokens].map { |count| token_count(count) }
      rates = rates_for(model, provider, counts[0] + counts[2] + counts[3])
      return nil unless rates

      apply_mode(priced_tokens(rates, *counts), rates.fetch(:entry), mode)
    end
    # rubocop:enable Metrics/ParameterLists

    # True when the call's cache tokens were priced at 0 because its rates
    # have no cache rate for them; false when they were priced, absent, or
    # the call is unpriced altogether.
    def self.cache_unpriced?(model:, input_tokens:, provider: nil, cache_read_tokens: 0, cache_write_tokens: 0)
      read = token_count(cache_read_tokens)
      write = token_count(cache_write_tokens)
      rates = rates_for(model, provider, token_count(input_tokens) + read + write)
      return false unless rates

      (read.positive? && rates[:cache_read].nil?) || (write.positive? && rates[:cache_write].nil?)
    end

    # A count that is not a non-negative Integer prices as 0, so accounting
    # never raises on a provider's missing or malformed count.
    def self.token_count(count)
      count.is_a?(Integer) && count.positive? ? count : 0
    end

    def self.rates_for(model, provider, total_input_tokens)
      catalog = Smith.config.pricing
      return nil unless catalog.is_a?(Hash)

      entry = lookup_entry(normalized_index(catalog), model, provider)
      resolve_rates(entry, total_input_tokens) if entry.is_a?(Hash)
    end

    def self.priced_tokens(rates, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
      (input_tokens * rates[:input]) + (output_tokens * rates[:output]) +
        (cache_read_tokens * (rates[:cache_read] || 0)) + (cache_write_tokens * (rates[:cache_write] || 0))
    end

    def self.apply_mode(cost, entry, mode)
      return cost unless mode == :batch

      discount = value_at(entry, :batch_discount)
      discount.is_a?(Numeric) ? cost * (1 - discount) : cost
    end

    def self.lookup_entry(index, model, provider)
      return index.fetch(:qualified)[[provider.to_s, model.to_s]] if provider

      index.fetch(:legacy)[model.to_s]
    end

    # Admission-time catalog validation. Call when the pricing catalog
    # is assigned (`config.pricing = Smith::Pricing.validate_catalog!(catalog)`)
    # so misconfiguration fails at configuration time instead of inside
    # an in-flight accounting path. Rejects legacy model-only keys,
    # unrecognized key shapes, non-Hash entries, keys that collide after
    # normalization, optional rates that are not non-negative Integers or
    # Floats, and a batch discount out of range or inside a tier. Returns
    # the catalog for assignment chaining.
    def self.validate_catalog!(catalog = Smith.config.pricing)
      CatalogValidation.validate!(catalog)
    end

    # A catalog key read as a Symbol or a String, as a catalog loaded from
    # JSON or YAML has.
    def self.value_at(source, name)
      source.key?(name) ? source[name] : source[name.to_s]
    end

    # The catalog is treated as immutable once assigned: normalization
    # runs once per catalog object and is memoized by identity, so
    # replacing the catalog means assigning a new Hash.
    NORMALIZATION_MUTEX = Mutex.new
    private_constant :NORMALIZATION_MUTEX

    def self.normalized_index(catalog)
      NORMALIZATION_MUTEX.synchronize do
        next @normalized_index if defined?(@normalized_source) && @normalized_source.equal?(catalog)

        @normalized_index = build_normalized_index(catalog)
        @normalized_source = catalog
        @normalized_index
      end
    end

    # Non-raising by design: compute_cost runs inside success and
    # failure accounting, so unrecognizable keys are skipped (their
    # usage stays unpriced) rather than raised. `validate_catalog!`
    # is the raising surface for the same rules.
    def self.build_normalized_index(catalog)
      catalog.each_with_object({ qualified: {}, legacy: {} }) do |(key, entry), index|
        provider, model = canonical_key(key)
        next unless model

        provider ? (index[:qualified][[provider, model].freeze] = entry) : (index[:legacy][model] = entry)
      end
    end

    # Returns [provider_or_nil, model] for a recognized key, nil otherwise.
    # Mirrors Smith::Agent::ModelReference: the first slash separates
    # provider from model, so slashed model ids are keyed with an explicit
    # provider segment ("openrouter/openai/gpt-5" or [provider, model]).
    def self.canonical_key(key)
      case key
      when Array then array_key(key)
      when String, Symbol then text_key(key.to_s)
      end
    end

    def self.array_key(key)
      provider, model = key.map { |part| scalar_key(part) } if key.length == 2
      [provider, model] if provider && model
    end

    def self.text_key(text)
      return if text.empty?
      return [nil, text] unless text.include?("/")

      provider, model = text.split("/", 2)
      [provider, model] unless provider.empty? || model.empty?
    end

    def self.scalar_key(value)
      text = value.to_s if value.is_a?(String) || value.is_a?(Symbol)
      text unless text.nil? || text.empty?
    end

    # Returns { input:, output:, cache_read:, cache_write:, entry: } or nil
    # if no applicable input and output rate. Tiered shape is recognized by
    # the presence of a :tiers key; flat shape is the legacy default. A tier
    # without its own cache rate uses the entry's.
    def self.resolve_rates(entry, total_input_tokens)
      tiers = value_at(entry, :tiers)
      rates = if tiers.is_a?(Array) && !tiers.empty?
                tier = tiers.find { |candidate| candidate.is_a?(Hash) && tier_applies?(candidate, total_input_tokens) }
                tier && rates_from(tier, defaults: entry)
              else
                rates_from(entry)
              end
      rates&.merge(entry:)
    end

    def self.rates_from(source, defaults: nil)
      rates = %i[input output cache_read cache_write].to_h { |name| [name, rate_at(source, defaults, name)] }
      rates if rates[:input] && rates[:output]
    end

    # A tier's own rate, else, for a cache rate, the entry's.
    def self.rate_at(source, defaults, name)
      rate = value_at(source, :"#{name}_cost_per_token")
      rate = value_at(defaults, :"#{name}_cost_per_token") if rate.nil? && defaults && CACHE_RATES.include?(name)
      rate if rate.is_a?(Numeric)
    end

    def self.tier_applies?(tier, input_tokens)
      maximum = value_at(tier, :max_input_tokens)
      maximum.nil? || input_tokens <= maximum
    end

    CACHE_RATES = %i[cache_read cache_write].freeze
    private_constant :CACHE_RATES

    private_class_method :rate_at, :lookup_entry, :normalized_index, :build_normalized_index, :canonical_key,
                         :array_key, :text_key, :scalar_key, :resolve_rates, :rates_from, :tier_applies?,
                         :priced_tokens, :apply_mode, :token_count, :rates_for, :value_at
  end
end
