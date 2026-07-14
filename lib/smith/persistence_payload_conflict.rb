# frozen_string_literal: true

module Smith
  class PersistencePayloadConflict < Error
    attr_reader :key

    def initialize(key:)
      @key = key
      super("persisted payload conflict for #{key.inspect}: the exact expected payload is no longer current")
    end
  end
end
