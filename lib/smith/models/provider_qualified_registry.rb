# frozen_string_literal: true

require "monitor"

module Smith
  module Models
    module ProviderQualifiedRegistry
      def self.extended(registry)
        registry.instance_variable_set(:@registry_monitor, Monitor.new)
        registry.instance_variable_set(:@registry_index, {})
      end

      def find(model_id, provider: nil)
        registry_monitor.synchronize do
          registered_keys = registered_keys_for(model_id, provider:)
          return nil if registered_keys.empty?

          reject_ambiguous_lookup!(model_id, registered_keys)
          resolve(registered_keys.first)
        end
      end

      def register(profile)
        registry_monitor.synchronize do
          profile = normalized_profile(profile)
          key = registry_key(profile.model_id, profile.provider)
          existing = key?(key) ? resolve(key) : nil

          return profile if existing == profile

          raise_collision!(key, existing, profile) if existing

          super(key, profile)
          index_profile(profile, key)
          profile
        end
      end

      def all
        registry_monitor.synchronize do
          keys.map { |key| resolve(key) }.sort_by do |profile|
            [profile.model_id, profile.provider.to_s]
          end
        end
      end

      def clear!
        registry_monitor.synchronize do
          @_container&.clear
          @registry_index = {}
        end
      end

      private

      attr_reader :registry_monitor, :registry_index

      def registered_keys_for(model_id, provider:)
        normalized_id = normalize_key(model_id)
        return registry_index.fetch(normalized_id, []) unless provider

        key = registry_key(normalized_id, provider)
        key?(key) ? [key] : []
      end

      def registry_key(model_id, provider)
        [provider.to_sym, normalize_key(model_id)]
      end

      def reject_ambiguous_lookup!(model_id, registered_keys)
        return unless registered_keys.length > 1

        providers = registered_keys.map { |key| resolve(key).provider.to_s }.sort
        raise AmbiguousProfileError,
              "model #{normalize_key(model_id).inspect} has profiles for multiple providers: " \
              "#{providers.join(", ")}; pass provider:"
      end

      def index_profile(profile, key)
        model_id = normalize_key(profile.model_id)
        registry_index[model_id] = [*registry_index.fetch(model_id, []), key].uniq.freeze
      end

      def normalized_profile(profile)
        Profile.new(
          **profile.to_h,
          model_id: normalize_key(profile.model_id).freeze,
          provider: profile.provider.to_sym
        )
      rescue NoMethodError, TypeError
        raise ArgumentError, "model profile must expose model_id, provider, and profile attributes"
      end

      def raise_collision!(key, existing, replacement)
        raise CollisionError,
              "model profile collision for #{key.inspect}: existing #{existing.inspect}, " \
              "replacement #{replacement.inspect}"
      end
    end
  end
end
