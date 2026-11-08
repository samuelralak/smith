# frozen_string_literal: true

require "active_support"
require "active_support/cache"

# One fresh instance of each persistence adapter Smith ships, by name, for
# specs that check a run stores and restores the same through all of them.
module EveryStoreAdapter
  # An in-memory client with the calls RedisStore makes.
  class RedisClient
    def initialize = @values = {}
    def get(key) = @values[key]
    def set(key, value, **) = @values.store(key, value)
    def del(*keys) = keys.count { |key| @values.delete(key) }
    def watch(_key) = yield
    def unwatch = nil
    def without_reconnect = yield

    def multi
      yield self
      ["OK"]
    end
  end

  def every_store_adapter
    SmithWorkflowStateRecord.delete_all
    {
      memory: Smith::PersistenceAdapters::Memory.new,
      active_record: Smith::PersistenceAdapters::ActiveRecordStore.new(model: SmithWorkflowStateRecord),
      redis: Smith::PersistenceAdapters::RedisStore.new(redis: RedisClient.new),
      cache_store: Smith::PersistenceAdapters::CacheStore.new(store: ActiveSupport::Cache::MemoryStore.new),
      rails_cache: Smith::PersistenceAdapters::RailsCache.new(store: ActiveSupport::Cache::MemoryStore.new)
    }
  end
end
