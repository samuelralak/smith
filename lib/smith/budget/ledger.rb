# frozen_string_literal: true

require_relative "amount_contract"
require_relative "amount_representation"
require_relative "ledger_publication"
require_relative "ledger_state"
require_relative "ledger_state_transition"
require_relative "public_state_validator"
require_relative "reservation"
require_relative "reservation_contract"

module Smith
  module Budget
    class Ledger
      attr_reader :limits

      def initialize(limits: {}, consumed: {})
        @mutex = Mutex.new
        @identity = Object.new.freeze
        @reservation_contract = ReservationContract.new(ledger_identity: @identity)
        initialize_contracts(limits)
        initialize_state(consumed)
      end

      def consumed
        @mutex.synchronize { @representation.externalize(@publication.state.consumed).freeze }
      end

      def reserve!(key, amount) = reserve_many!(key => amount)

      def reserve_many!(reservations)
        amounts = validated_amounts(reservations, "budget reservation")
        @mutex.synchronize { create_reservation(amounts) }
      end

      def reconcile!(reservation, actual_amount)
        amounts = @reservation_contract.amounts!(reservation)
        unless amounts.one?
          raise ArgumentError, "single-dimension reconciliation requires a single-dimension reservation"
        end

        reconcile_many!(reservation, actual: { amounts.keys.first => actual_amount }).values.first
      end

      def reconcile_many!(reservation, actual:)
        token = @reservation_contract.token!(reservation)
        actuals = validated_amounts(actual, "actual budget")
        @mutex.synchronize { settle_reservation(token, actuals) }
      end

      def release!(reservation)
        released = release_many!(reservation)
        released.values.first if released.one?
      end

      def release_many!(reservation)
        token = @reservation_contract.token!(reservation)
        @mutex.synchronize { release_reservation(token) }
      end

      def remaining(key)
        dimension = @amount_contract.dimension!(key)
        @amount_contract.known_dimension!(dimension)
        @mutex.synchronize do
          amount = @state_transition.remaining(@publication.state, dimension)
          @representation.externalize_amount(dimension, amount)
        end
      end

      private

      def initialize_contracts(limits)
        @limits = AmountContract.new.own_hash!(limits, "budget limit").freeze
        @amount_contract = AmountContract.new(limits: @limits)
        @representation = AmountRepresentation.new(limits: @limits)
        internal_limits = @representation.internalize(@limits)
        @state_transition = LedgerStateTransition.new(limits: internal_limits)
        @public_state_validator = PublicStateValidator.new(
          limits: @limits,
          representation: @representation,
          state_transition: @state_transition
        )
      end

      def initialize_state(consumed)
        initial_consumed = @amount_contract.own_hash!(consumed, "consumed budget")
        @amount_contract.known_hash!(initial_consumed)
        internal_consumed = @representation.internalize(initial_consumed)
        state = LedgerState.new(consumed: internal_consumed, reserved: {})
        @publication = LedgerPublication.new(state: @public_state_validator.call(state))
      end

      def validated_amounts(amounts, label)
        external = @amount_contract.own_hash!(amounts, label)
        @amount_contract.known_hash!(external)
        @representation.internalize(external)
      end

      def create_reservation(amounts)
        token = Object.new.freeze
        receipt = Reservation.new(
          ledger_identity: @identity,
          token:,
          amounts: @representation.externalize(amounts)
        )
        next_state = @state_transition.reserve(@publication.state, amounts)
        @publication.add(@public_state_validator.call(next_state), token:, amounts:)
        receipt
      end

      def settle_reservation(token, actuals)
        reserved_amounts = active_reservation!(token)
        @amount_contract.matching_dimensions!(reserved_amounts, actuals)
        next_state = @state_transition.reconcile(@publication.state, reserved_amounts, actuals)
        consumed = @representation.externalize(next_state.consumed.slice(*actuals.keys))
        @publication.remove(@public_state_validator.call(next_state), token:, amounts: reserved_amounts)
        consumed
      end

      def release_reservation(token)
        reserved_amounts = active_reservation!(token)
        next_state = @state_transition.release(@publication.state, reserved_amounts)
        remaining = @representation.externalize(next_state.reserved.slice(*reserved_amounts.keys))
        @publication.remove(@public_state_validator.call(next_state), token:, amounts: reserved_amounts)
        remaining
      end

      def active_reservation!(token)
        @publication.reservation(token) ||
          raise(ArgumentError, "budget reservation is unknown or already settled")
      end
    end
  end
end
