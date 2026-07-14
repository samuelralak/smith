# frozen_string_literal: true

require "monitor"
require_relative "persistence_adapters/active_record_connection_errors"
require_relative "persistence_adapters/active_record_initial_write"
require_relative "persistence_adapters/active_record_exact_write"
require_relative "persistence_adapters/active_record_exact_store"
require_relative "persistence_adapters/payload_version"
require_relative "persistence_adapters/version_expectation"
require_relative "persistence_adapters/cache_store"
require_relative "persistence_adapters/rails_cache"
require_relative "persistence_adapters/redis_versioned_write"
require_relative "persistence_adapters/redis_exact_write"
require_relative "persistence_adapters/redis_store"
require_relative "persistence_adapters/active_record_store"
require_relative "persistence_adapters/memory"
require_relative "persistence_adapters/retry"

module Smith
  module PersistenceAdapters
    SolidCache = RailsCache

    # REQUIRED_METHODS is the immutable adapter contract: any object
    # responding to these is a valid Smith persistence adapter. This
    # contract is preserved across the Phase B persistence hardening
    # work; new optional capabilities (store_versioned, TTL kwarg) are
    # additive and queried via respond_to?.
    REQUIRED_METHODS = %i[store fetch delete].freeze

    # OPTIONAL_METHODS: capabilities adapters MAY implement. Callers
    # check support via `supports?(adapter, capability)` and fall back
    # gracefully (e.g., Workflow#persist! warns once and uses plain
    # `store` when `store_versioned` is missing).
    OPTIONAL_METHODS = %i[
      store_versioned replace_exact persistence_identity record_heartbeat last_heartbeat
      transaction_open? transaction_identity
    ].freeze

    def self.resolve(adapter, **options)
      return nil if adapter.nil?
      return validate!(adapter) if adapter_like?(adapter)

      if adapter.is_a?(Class)
        instance = options.empty? ? adapter.new : adapter.new(**options)
        return validate!(instance)
      end

      validate!(build(adapter, options))
    end

    def self.adapter_like?(adapter)
      REQUIRED_METHODS.all? { |method_name| adapter.respond_to?(method_name) }
    end

    def self.validate!(adapter)
      return adapter if adapter_like?(adapter)

      missing = REQUIRED_METHODS.reject { |method_name| adapter.respond_to?(method_name) }
      raise ArgumentError, "Persistence adapter must implement #{missing.join(", ")}"
    end

    def self.build(adapter, options)
      case adapter.to_sym
      when :cache_store then CacheStore.new(**options)
      when :rails_cache, :solid_cache then RailsCache.new(**options)
      when :redis then RedisStore.new(**options)
      when :active_record then ActiveRecordStore.new(**options)
      when :memory then Memory.new(**options)
      else raise ArgumentError, "Unknown persistence adapter #{adapter.inspect}"
      end
    end
    private_class_method :build

    # Capability introspection used by Workflow#persist! to decide
    # whether the adapter supports optimistic locking via store_versioned.
    def self.supports?(adapter, capability)
      adapter.respond_to?(capability)
    end

    # Tracks which adapter CLASSES have already warned about missing
    # store_versioned capability. One warning per adapter class per
    # Smith boot (not per workflow instance, not per persist call).
    @_warned_classes = Set.new
    @_warned_monitor = Monitor.new

    def self.warn_missing_versioning(adapter)
      klass = adapter.class
      @_warned_monitor.synchronize do
        return if @_warned_classes.include?(klass)

        @_warned_classes << klass
      end

      Smith.config.logger&.warn(
        "#{klass.name} does not implement store_versioned; " \
        "optimistic locking is disabled for this adapter. " \
        "Switch to RedisStore, ActiveRecordStore (with lock_version column), " \
        "or the Memory adapter for race protection."
      )
    end

    @_warned_heartbeat_classes = Set.new
    @_warned_heartbeat_monitor = Monitor.new

    def self.warn_missing_heartbeat(adapter)
      klass = adapter.class
      @_warned_heartbeat_monitor.synchronize do
        return if @_warned_heartbeat_classes.include?(klass)

        @_warned_heartbeat_classes << klass
      end

      Smith.config.logger&.warn(
        "#{klass.name} does not implement record_heartbeat/last_heartbeat; " \
        "Smith::Workflow.stuck_for? falls back to payload['updated_at'] parsing. " \
        "For accurate liveness probes, switch to RedisStore or Memory."
      )
    end
  end
end
