# frozen_string_literal: true

require "dry-initializer"

module Smith
  module Budget
    class PublicStateValidator
      extend Dry::Initializer

      option :limits
      option :representation
      option :state_transition

      def call(state)
        representation.externalize(state.consumed)
        representation.externalize(state.reserved)
        limits.each_key do |dimension|
          remaining = state_transition.remaining(state, dimension)
          representation.externalize_amount(dimension, remaining)
        end
        state
      end
    end
  end
end
