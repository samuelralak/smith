# frozen_string_literal: true

module Smith
  module Pricing
    # Admission-time catalog validation, the raising surface for the rules
    # `compute_cost` applies without raising. See Pricing.validate_catalog!.
    module CatalogValidation
      OPTIONAL_RATE_KEYS = %i[cache_read_cost_per_token cache_write_cost_per_token].freeze

      module_function

      def validate!(catalog)
        return catalog if catalog.nil?
        raise Smith::PricingConfigurationError, "pricing catalog must be a Hash" unless catalog.is_a?(Hash)

        catalog.each_with_object({}) do |(key, entry), seen|
          provider, model = validated_key!(key)
          validate_entry!(key, entry)
          reject_collision!(seen, key, provider, model)
        end
        catalog
      end

      def validated_key!(key)
        provider, model = Pricing.__send__(:canonical_key, key)
        raise Smith::PricingConfigurationError, "unrecognized pricing catalog key #{key.inspect}" unless model
        return [provider, model] if provider

        raise Smith::PricingConfigurationError, "pricing for #{model} must use a provider-qualified catalog key"
      end

      def validate_entry!(key, entry)
        unless entry.is_a?(Hash)
          raise Smith::PricingConfigurationError, "pricing entry for #{key.inspect} must be a Hash"
        end

        tiers = Pricing.__send__(:value_at, entry, :tiers)
        tiers = [] unless tiers.is_a?(Array)
        [entry, *tiers].each { |rates| validate_optional_rates!(key, rates) }
        values_at(entry, :batch_discount).each { |discount| validate_batch_discount!(key, discount) }
        reject_tier_batch_discount!(key, tiers)
      end

      def validate_optional_rates!(key, rates)
        return unless rates.is_a?(Hash)

        OPTIONAL_RATE_KEYS.each do |name|
          next if values_at(rates, name).all? { |rate| non_negative_number?(rate) }

          raise Smith::PricingConfigurationError, "#{name} for #{key.inspect} must be a non-negative Integer or Float"
        end
      end

      # Every form of a key the entry carries, Symbol and String, so a
      # malformed value cannot hide behind a valid one under the other form.
      def values_at(source, name)
        [name, name.to_s].select { |form| source.key?(form) }.map { |form| source[form] }.compact
      end

      def validate_batch_discount!(key, discount)
        return if non_negative_number?(discount) && discount < 1

        raise Smith::PricingConfigurationError, "batch_discount for #{key.inspect} must be at least 0 and below 1"
      end

      # A batch discount applies to a whole call, so it belongs on the entry;
      # one inside a tier would never be read.
      def reject_tier_batch_discount!(key, tiers)
        return unless tiers.any? { |tier| tier.is_a?(Hash) && values_at(tier, :batch_discount).any? }

        raise Smith::PricingConfigurationError, "batch_discount for #{key.inspect} belongs on the entry, not a tier"
      end

      def non_negative_number?(value)
        (value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)) && value >= 0
      end

      def reject_collision!(seen, key, provider, model)
        previous = seen[[provider, model]]
        if previous
          raise Smith::PricingConfigurationError,
                "pricing catalog keys #{previous.inspect} and #{key.inspect} collide as #{provider}/#{model}"
        end

        seen[[provider, model]] = key
      end
    end

    private_constant :CatalogValidation
  end
end
