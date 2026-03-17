# frozen_string_literal: true

require "dry-container"

module Smith
  class Agent
    module Registry
      extend Dry::Container::Mixin

      def self.find(name)
        key = name.to_sym
        key?(key) ? resolve(key) : nil
      end
    end
  end
end
