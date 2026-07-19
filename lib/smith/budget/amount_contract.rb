# frozen_string_literal: true

require "dry-initializer"

module Smith
  module Budget
    class AmountContract
      extend Dry::Initializer

      option :limits, default: proc {}

      def own_hash!(amounts, label)
        case amounts
        when Hash then own_amount_hash(amounts, label)
        else raise ArgumentError, "#{label} values must be a Hash"
        end
      end

      def known_hash!(amounts)
        amounts.each_key { known_dimension!(_1) }
      end

      def known_dimension!(key)
        return if limits&.key?(key)

        raise ArgumentError, "unknown budget dimension #{key.inspect}"
      end

      def matching_dimensions!(reserved, actual)
        return if reserved.length == actual.length && reserved.each_key.all? { actual.key?(_1) }

        raise ArgumentError, "reserved and actual budget dimensions must match"
      end

      def dimension!(key)
        case key
        when Symbol then key
        when String then String.new(key).freeze
        else raise ArgumentError, "budget dimension keys must be symbols or strings"
        end
      end

      private

      def own_amount_hash(amounts, label)
        {}.tap do |owned|
          Hash.instance_method(:each_pair).bind_call(amounts) do |key, amount|
            owned[dimension!(key)] = own_amount!(amount, label)
          end
        end
      end

      def own_amount!(amount, label)
        validate_amount!(amount, label)
      end

      def validate_amount!(amount, label)
        case amount
        when Integer then return amount if amount >= 0
        when Float then return amount if amount.finite? && amount >= 0
        end

        raise ArgumentError, "#{label} values must be finite and non-negative Integer or Float values"
      end
    end
  end
end
