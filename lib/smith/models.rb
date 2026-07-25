# frozen_string_literal: true

require "dry-container"

require_relative "models/profile"
require_relative "models/ambiguous_profile_error"
require_relative "models/collision_error"
require_relative "models/provider_qualified_registry"

module Smith
  # Capability registry for model ids. Decoupled from Smith.config.pricing
  # (per-installation billing) — this catalog describes payload-shape
  # capabilities (thinking encoding, temperature acceptance, endpoint
  # preferences for tools+thinking).
  #
  # The library ships NO specific model_id declarations. Smith::Models::Inference
  # provides PATTERN-BASED PROVIDER RULES that match model_ids at runtime
  # (e.g., "Anthropic Opus 4.7+ uses adaptive thinking"). Applications register
  # explicit Profile overrides via Smith::Models.register ONLY when they have
  # a custom model that diverges from its provider's default behavior.
  #
  # Resolution order in find_or_infer(model_id):
  #   1. Application-registered explicit Profile (override wins)
  #   2. Library Inference rule match
  #   3. Safe default (no thinking, accepts temp, no routing)
  module Models
    extend Dry::Container::Mixin
    extend ProviderQualifiedRegistry

    def self.normalize_key(model_id)
      model_id.to_s
    end

    # Application overrides first, then Inference rules, then safe default.
    def self.find_or_infer(model_id, provider: nil)
      find(model_id, provider:) || infer(model_id, provider:)
    end

    def self.infer(model_id, provider: nil)
      inferred = Inference.profile_for(model_id) if defined?(Inference)
      return inferred_profile_for_provider(inferred, provider) if inferred

      Profile.new(
        model_id: normalize_key(model_id),
        provider: provider || guess_provider(model_id),
        thinking_shape: nil,
        accepts_temperature: true,
        tools_with_thinking_native: false,
        tools_with_thinking_route: nil
      )
    end

    def self.inferred_profile_for_provider(profile, provider)
      return profile unless provider && profile.provider != provider.to_sym

      Profile.new(
        **profile.to_h,
        provider: provider.to_sym,
        tools_with_thinking_native: false,
        tools_with_thinking_route: nil
      )
    end
    private_class_method :inferred_profile_for_provider

    PROVIDER_PATTERNS = {
      anthropic: /\Aclaude/i,
      openai: /\A(gpt|o\d)/i,
      gemini: /\Agemini/i
    }.freeze
    private_constant :PROVIDER_PATTERNS

    def self.guess_provider(model_id)
      key = normalize_key(model_id)
      PROVIDER_PATTERNS.each { |provider, pattern| return provider if key.match?(pattern) }
      :unknown
    end
  end
end
