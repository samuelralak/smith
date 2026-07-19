# frozen_string_literal: true

require "bigdecimal"
require "dry-initializer"
require_relative "decimal_context"

module Smith
  module Budget
    class LedgerStateTransition
      extend Dry::Initializer

      option :limits

      def reserve(state, amounts)
        DecimalContext.call do
          amounts.each do |key, amount|
            requested = state.consumed[key] + state.reserved[key] + amount
            raise BudgetExceeded unless requested.finite? && requested <= limits.fetch(key)
          end

          LedgerState.new(consumed: state.consumed, reserved: add(state.reserved, amounts))
        end
      end

      def reconcile(state, reserved_amounts, actuals)
        DecimalContext.call do
          LedgerState.new(
            consumed: add(state.consumed, actuals),
            reserved: subtract(state.reserved, reserved_amounts)
          )
        end
      end

      def release(state, reserved_amounts)
        DecimalContext.call do
          LedgerState.new(
            consumed: state.consumed,
            reserved: subtract(state.reserved, reserved_amounts)
          )
        end
      end

      def remaining(state, key)
        DecimalContext.call do
          amount = limits.fetch(key) - state.consumed[key] - state.reserved[key]
          amount.negative? ? BigDecimal("0") : amount
        end
      end

      private

      def add(current, amounts)
        merge(current, amounts) { |value, amount| value + amount }
      end

      def subtract(current, amounts)
        merge(current, amounts) { |value, amount| value - amount }
      end

      def merge(current, amounts)
        current.dup.tap do |result|
          amounts.each do |key, amount|
            value = yield(current.fetch(key, 0), amount)
            raise ArgumentError, "budget state values must be non-negative" if value.negative?

            result[key] = value
          end
        end
      end
    end
  end
end
