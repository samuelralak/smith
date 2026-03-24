# frozen_string_literal: true

module Smith
  module PersistenceAdapters
    class RailsCache < CacheStore
      def initialize(store: nil, namespace: "smith")
        super(store: store || method(:default_store), namespace:)
      end

      private

      def default_store
        cache = defined?(::Rails) && ::Rails.respond_to?(:cache) ? ::Rails.cache : nil
        raise ArgumentError, "Rails.cache is not available" unless cache

        cache
      end
    end
  end
end
