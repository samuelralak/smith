# frozen_string_literal: true

require "dry-container"
require "monitor"

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

    class CollisionError < Smith::Error; end

    def self.normalize_key(model_id)
      model_id.to_s
    end

    def self.find(model_id)
      registry_monitor.synchronize do
        key = normalize_key(model_id)
        key?(key) ? resolve(key) : nil
      end
    end

    # Application overrides first, then Inference rules, then safe default.
    def self.find_or_infer(model_id, provider: nil)
      find(model_id) || infer(model_id, provider: provider)
    end

    def self.infer(model_id, provider: nil)
      inferred = Inference.profile_for(model_id) if defined?(Inference)
      return inferred if inferred

      Profile.new(
        model_id:                   normalize_key(model_id),
        provider:                   provider || guess_provider(model_id),
        thinking_shape:             nil,
        accepts_temperature:        true,
        tools_with_thinking_native: false,
        tools_with_thinking_route:  nil
      )
    end

    # Register a Profile. Idempotent when re-registering an identical
    # profile; replaces silently on Rails-reload (same model_id, possibly
    # different Profile object after autoload swap); raises CollisionError
    # on a genuinely conflicting registration.
    #
    # The stale-reload-binding pattern mirrors Smith::Agent::Registry
    # (agent/registry.rb:118-124) which solves the same problem for
    # agent classes during Rails autoreload.
    def self.register(profile)
      registry_monitor.synchronize do
        key = normalize_key(profile.model_id)
        existing = key?(key) ? resolve(key) : nil

        return profile if existing == profile

        if existing && stale_reload_binding?(existing, profile)
          # Same model_id, value-unequal Profile — Rails reload swap.
          # Document trade-off: a host that intentionally re-registers with
          # different capabilities also gets silent replacement (same
          # behavior Smith::Agent::Registry chose).
          _container.delete(key)
          super(key, profile)
          return profile
        end

        if existing
          raise CollisionError,
                "model #{key.inspect} already registered with a different profile"
        end

        super(key, profile)
        profile
      end
    end

    def self.all
      registry_monitor.synchronize do
        keys.sort.map { |k| resolve(k) }
      end
    end

    def self.clear!
      registry_monitor.synchronize { @_container&.clear }
    end

    # Eagerly initialized at module load so concurrent first-callers
    # cannot race the `||=` lazy-init and end up with separate Monitor
    # instances (which would partially defeat synchronization).
    @_registry_monitor = Monitor.new

    def self.registry_monitor
      @_registry_monitor
    end

    PROVIDER_PATTERNS = {
      anthropic: /\Aclaude/i,
      openai:    /\A(gpt|o\d)/i,
      gemini:    /\Agemini/i
    }.freeze
    private_constant :PROVIDER_PATTERNS

    def self.guess_provider(model_id)
      key = normalize_key(model_id)
      PROVIDER_PATTERNS.each { |provider, pattern| return provider if key.match?(pattern) }
      :unknown
    end

    # Same model_id but value-unequal Profile objects (e.g., a host
    # tweaked a built-in profile in config/initializers and Rails
    # reloaded). Replace silently rather than raise.
    def self.stale_reload_binding?(existing, profile)
      existing.model_id == profile.model_id
    end
    private_class_method :stale_reload_binding?
  end
end
