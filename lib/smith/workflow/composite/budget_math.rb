# frozen_string_literal: true

require "bigdecimal"
require "dry-initializer"

require_relative "../../budget/decimal_context"

module Smith
  class Workflow
    module Composite
      class BudgetMath
        extend Dry::Initializer

        HASH_EACH_PAIR = Hash.instance_method(:each_pair)
        private_constant :HASH_EACH_PAIR

        param :consumptions

        def self.sum(consumptions) = new(consumptions).sum

        def sum
          Budget::DecimalContext.call do
            totals = {}
            integer_dimensions = {}
            consumptions.each { accumulate!(_1, totals, integer_dimensions) }
            externalize(totals, integer_dimensions)
          end
        end

        private

        def accumulate!(value, totals, integer_dimensions)
          raise ArgumentError, "composite budget consumption must be a Hash" unless value.is_a?(Hash)

          HASH_EACH_PAIR.bind_call(value) do |dimension, amount|
            key = dimension.to_s
            totals[key] = totals.fetch(key, BigDecimal("0")) + BigDecimal(amount.to_s)
            integer_dimensions[key] = integer_dimensions.fetch(key, true) && amount.is_a?(Integer)
          end
        end

        def externalize(totals, integer_dimensions)
          totals.to_h do |dimension, total|
            value = integer_dimensions.fetch(dimension) ? total.to_i : total.to_f
            [dimension, value]
          end.freeze
        end
      end
    end
  end
end
