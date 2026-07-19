# frozen_string_literal: true

require "bigdecimal"
require "dry-initializer"

module Smith
  module Budget
    class AmountRepresentation
      extend Dry::Initializer

      option :limits

      def internalize(amounts)
        amounts.to_h { |key, amount| [key, internalize_amount(amount)] }
      end

      def externalize(amounts)
        amounts.to_h { |key, amount| [key, externalize_amount(key, amount)] }
      end

      def externalize_amount(key, amount)
        return finite_float!(amount) if limits.fetch(key).is_a?(Float)
        return amount if amount.is_a?(Integer)
        return amount.to_i if amount.frac.zero?

        finite_float!(amount)
      end

      private

      def internalize_amount(amount)
        BigDecimal(amount.to_s)
      end

      def finite_float!(amount)
        external = amount.to_f
        return external if external.finite?

        raise ArgumentError, "budget state values must remain JSON-safe finite numerics"
      end
    end
  end
end
