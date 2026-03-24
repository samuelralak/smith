# frozen_string_literal: true

require_relative "persistence_adapters/cache_store"
require_relative "persistence_adapters/rails_cache"
require_relative "persistence_adapters/redis_store"
require_relative "persistence_adapters/active_record_store"

module Smith
  module PersistenceAdapters
    SolidCache = RailsCache
    REQUIRED_METHODS = %i[store fetch delete].freeze

    def self.resolve(adapter, **options)
      return nil if adapter.nil?
      return validate!(adapter) if adapter_like?(adapter)

      if adapter.is_a?(Class)
        instance = options.empty? ? adapter.new : adapter.new(**options)
        return validate!(instance)
      end

      built_in = case adapter.to_sym
      when :cache_store
        CacheStore.new(**options)
      when :rails_cache, :solid_cache
        RailsCache.new(**options)
      when :redis
        RedisStore.new(**options)
      when :active_record
        ActiveRecordStore.new(**options)
      else
        raise ArgumentError, "Unknown persistence adapter #{adapter.inspect}"
      end

      validate!(built_in)
    end

    def self.adapter_like?(adapter)
      REQUIRED_METHODS.all? { |method_name| adapter.respond_to?(method_name) }
    end

    def self.validate!(adapter)
      return adapter if adapter_like?(adapter)

      missing = REQUIRED_METHODS.reject { |method_name| adapter.respond_to?(method_name) }
      raise ArgumentError, "Persistence adapter must implement #{missing.join(', ')}"
    end
  end
end
