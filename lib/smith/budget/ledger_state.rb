# frozen_string_literal: true

module Smith
  module Budget
    class LedgerState
      attr_reader :consumed, :reserved

      def initialize(consumed:, reserved:)
        @consumed = amount_hash(consumed)
        @reserved = amount_hash(reserved)
        freeze
      end

      private

      def amount_hash(amounts)
        Hash.new(0).merge(amounts).freeze
      end
    end
  end
end
