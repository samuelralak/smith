# frozen_string_literal: true

module Smith
  module Budget
    class Reservation
      attr_reader :amounts

      def initialize(ledger_identity:, token:, amounts:)
        @ledger_identity = ledger_identity
        @token = token
        @amounts = amounts.dup.freeze
        freeze
      end

      def identity_for(ledger_identity)
        @token if @ledger_identity.equal?(ledger_identity)
      end
    end
  end
end
