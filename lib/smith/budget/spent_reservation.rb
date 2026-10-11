# frozen_string_literal: true

module Smith
  module Budget
    # Reserving for spending that has already happened (a batch result
    # delivered after its request was admitted): never refused, so the
    # reservation can be reconciled with what was spent, past the limits if
    # need be. Part of Ledger.
    module SpentReservation
      def reserve_spent!(reservations)
        amounts = validated_amounts(reservations, "budget reservation")
        @mutex.synchronize { create_reservation(amounts, checked: false) }
      end
    end
  end
end

Smith::Budget::Ledger.include(Smith::Budget::SpentReservation)
