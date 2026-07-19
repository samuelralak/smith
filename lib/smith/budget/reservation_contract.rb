# frozen_string_literal: true

require "dry-initializer"

module Smith
  module Budget
    class ReservationContract
      extend Dry::Initializer

      option :ledger_identity

      def token!(reservation)
        validate_receipt!(reservation)
        reservation.identity_for(ledger_identity) ||
          raise(ArgumentError, "budget reservation belongs to another ledger")
      end

      def amounts!(reservation)
        token!(reservation)
        reservation.amounts
      end

      private

      def validate_receipt!(reservation)
        case reservation
        when Reservation then return
        end

        raise ArgumentError, "budget settlement requires a reservation receipt"
      end
    end
  end
end
