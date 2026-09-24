# frozen_string_literal: true

require "bigdecimal"
require "dry-initializer"
require_relative "decimal_context"

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

      # Remaining capacity, or one of parts equal shares of it, is reserved as
      # read, so parts reservations of the external value must never exceed the
      # exact amount. An Integer keeps floor division; a Float steps down until
      # its decimal form fits, which takes O(1) steps because Float division
      # lands within one ulp of the exact share.
      def externalize_remaining(key, amount, parts = 1)
        unless parts.is_a?(Integer) && parts.positive?
          raise ArgumentError, "budget share parts must be a positive Integer"
        end

        share = externalize_amount(key, amount) / parts
        return share unless share.is_a?(Float)

        DecimalContext.call do
          share = share.prev_float while internalize_amount(share) * parts > amount
        end
        share
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
