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
    # usage stays visibly unpriced (nil cost). This method never raises,
    # so accounting paths cannot mask a provider error with a pricing
    # configuration error. The legacy-only-key policy is enforced at
    # catalog admission time via `validate_catalog!`.
    # rubocop:disable Metrics/ParameterLists
    def self.compute_cost(model:, input_tokens:, output_tokens:, provider: nil, cache_read_tokens: 0,
                          cache_write_tokens: 0, mode: :sync)
      catalog = Smith.config.pricing
      return nil unless catalog.is_a?(Hash)

      entry = lookup_entry(normalized_index(catalog), model, provider)
      return nil unless entry

      rates = resolve_rates(entry, input_tokens + cache_read_tokens + cache_write_tokens)
      return nil unless rates

      cost = priced_tokens(rates, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
      apply_mode(cost, entry, mode)
    end
    # rubocop:enable Metrics/ParameterLists

    def self.priced_tokens(rates, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
      (input_tokens * rates[:input]) + (output_tokens * rates[:output]) +
        (cache_read_tokens * (rates[:cache_read] || 0)) + (cache_write_tokens * (rates[:cache_write] || 0))
    end

    def self.apply_mode(cost, entry, mode)
      return cost unless mode == :batch

      discount = entry[:batch_discount] || entry["batch_discount"]
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
    # unrecognized key shapes, non-Hash entries, and keys that collide
    # after normalization. Returns the catalog for assignment chaining.
    def self.validate_catalog!(catalog = Smith.config.pricing)
      return catalog if catalog.nil?
      raise Smith::PricingConfigurationError, "pricing catalog must be a Hash" unless catalog.is_a?(Hash)

      catalog.each_with_object({}) do |(key, entry), seen|
        provider, model = validated_key!(key)
        validate_entry!(key, entry)
        reject_collision!(seen, key, provider, model)
      end
      catalog
    end

    def self.validated_key!(key)
      provider, model = canonical_key(key)
      raise Smith::PricingConfigurationError, "unrecognized pricing catalog key #{key.inspect}" unless model
      return [provider, model] if provider

      raise Smith::PricingConfigurationError, "pricing for #{model} must use a provider-qualified catalog key"
    end

    OPTIONAL_RATE_KEYS = %i[cache_read_cost_per_token cache_write_cost_per_token].freeze
    private_constant :OPTIONAL_RATE_KEYS

    def self.validate_entry!(key, entry)
      raise Smith::PricingConfigurationError, "pricing entry for #{key.inspect} must be a Hash" unless entry.is_a?(Hash)

      tiers = entry[:tiers] || entry["tiers"]
      [entry, *(tiers.is_a?(Array) ? tiers : [])].each { |rates| validate_optional_rates!(key, rates) }
      validate_batch_discount!(key, entry[:batch_discount] || entry["batch_discount"])
    end

    def self.validate_optional_rates!(key, rates)
      return unless rates.is_a?(Hash)

      OPTIONAL_RATE_KEYS.each do |name|
        next if valid_optional_rate?(rates[name] || rates[name.to_s])

        raise Smith::PricingConfigurationError, "#{name} for #{key.inspect} must be a non-negative number"
      end
    end

    def self.valid_optional_rate?(rate)
      rate.nil? || (rate.is_a?(Numeric) && rate.finite? && rate >= 0)
    end

    def self.validate_batch_discount!(key, discount)
      return if discount.nil? || (discount.is_a?(Numeric) && discount >= 0 && discount < 1)

      raise Smith::PricingConfigurationError, "batch_discount for #{key.inspect} must be at least 0 and below 1"
    end

    def self.reject_collision!(seen, key, provider, model)
      previous = seen[[provider, model]]
      if previous
        raise Smith::PricingConfigurationError,
              "pricing catalog keys #{previous.inspect} and #{key.inspect} collide as #{provider}/#{model}"
      end

      seen[[provider, model]] = key
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

    # Returns { input:, output:, cache_read:, cache_write: } or nil if no
    # applicable input and output rate. Tiered shape is recognized by the
    # presence of a :tiers key; flat shape is the legacy default.
    def self.resolve_rates(entry, total_input_tokens)
      tiers = entry[:tiers] || entry["tiers"]
      if tiers.is_a?(Array) && !tiers.empty?
        tier = tiers.find { |candidate| tier_applies?(candidate, total_input_tokens) }
        tier && rates_from(tier)
      else
        rates_from(entry)
      end
    end

    def self.rates_from(source)
      rates = %i[input output cache_read cache_write].to_h do |name|
        rate = source[:"#{name}_cost_per_token"] || source["#{name}_cost_per_token"]
        [name, rate.is_a?(Numeric) ? rate : nil]
      end
      rates if rates[:input] && rates[:output]
    end

    def self.tier_applies?(tier, input_tokens)
      maximum = tier[:max_input_tokens] || tier["max_input_tokens"]
      maximum.nil? || input_tokens <= maximum
    end

    private_class_method :lookup_entry, :validated_key!, :validate_entry!, :reject_collision!,
                         :normalized_index, :build_normalized_index, :canonical_key, :array_key,
                         :text_key, :scalar_key, :resolve_rates, :rates_from, :tier_applies?,
                         :priced_tokens, :apply_mode, :validate_optional_rates!, :valid_optional_rate?,
                         :validate_batch_discount!
  end
end
