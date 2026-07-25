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
    def self.compute_cost(model:, input_tokens:, output_tokens:, provider: nil)
      catalog = Smith.config.pricing
      return nil unless catalog.is_a?(Hash)

      entry = lookup_entry(normalized_index(catalog), model, provider)
      return nil unless entry

      input_rate, output_rate = resolve_rates(entry, input_tokens)
      return nil unless input_rate

      (input_tokens * input_rate) + (output_tokens * output_rate)
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

    def self.validate_entry!(key, entry)
      return if entry.is_a?(Hash)

      raise Smith::PricingConfigurationError, "pricing entry for #{key.inspect} must be a Hash"
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

    # Returns [input_rate, output_rate] or nil if no applicable rate.
    # Tiered shape is recognized by the presence of a :tiers key; flat
    # shape is the legacy default.
    def self.resolve_rates(entry, input_tokens)
      tiers = entry[:tiers] || entry["tiers"]
      if tiers.is_a?(Array) && !tiers.empty?
        resolve_tiered(tiers, input_tokens)
      else
        flat = [entry[:input_cost_per_token], entry[:output_cost_per_token]]
        return nil unless flat.all?(Numeric)

        flat
      end
    end

    def self.resolve_tiered(tiers, input_tokens)
      tier = tiers.find { |candidate| tier_applies?(candidate, input_tokens) }
      return nil unless tier

      rates = [
        tier[:input_cost_per_token] || tier["input_cost_per_token"],
        tier[:output_cost_per_token] || tier["output_cost_per_token"]
      ]
      rates if rates.all?(Numeric)
    end

    def self.tier_applies?(tier, input_tokens)
      maximum = tier[:max_input_tokens] || tier["max_input_tokens"]
      maximum.nil? || input_tokens <= maximum
    end

    private_class_method :lookup_entry, :validated_key!, :validate_entry!, :reject_collision!,
                         :normalized_index, :build_normalized_index, :canonical_key, :array_key,
                         :text_key, :scalar_key, :resolve_rates, :resolve_tiered, :tier_applies?
  end
end
