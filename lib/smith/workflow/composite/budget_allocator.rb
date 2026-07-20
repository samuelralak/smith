# frozen_string_literal: true

require "bigdecimal"
require "dry-initializer"

require_relative "../../budget/decimal_context"
require_relative "../../budget/ledger"
require_relative "plan"

module Smith
  class Workflow
    module Composite
      class BudgetAllocator
        extend Dry::Initializer

        TOKEN_DIMENSIONS = %i[total_tokens token_limit].freeze
        SUPPORTED_DIMENSIONS = (TOKEN_DIMENSIONS + %i[total_cost]).freeze

        option :ledger
        option :branch_count

        def initialize(...)
          super
          unless ledger.is_a?(Budget::Ledger)
            raise ArgumentError, "composite budget allocation requires a budget ledger"
          end

          Plan.validate_branch_count!(branch_count)
          @remaining = ledger.limits.to_h { |dimension, _| [dimension, ledger.remaining(dimension)] }.freeze
        end

        def call(ordinal:, caps: {})
          validate_ordinal!(ordinal)

          @remaining.to_h do |dimension, amount|
            [dimension, capped_share(dimension, amount, ordinal, caps[dimension])]
          end.freeze
        end

        private

        def validate_ordinal!(ordinal)
          return if ordinal.is_a?(Integer) && ordinal.between?(0, branch_count - 1)

          raise ArgumentError, "composite branch ordinal is outside the allocation"
        end

        def capped_share(dimension, amount, ordinal, cap)
          unless cap.nil? || (cap.is_a?(Numeric) && cap.finite? && cap >= 0)
            raise ArgumentError, "composite branch budget cap must be a finite non-negative number"
          end

          allocation = share(dimension, amount, ordinal)
          cap.nil? ? allocation : [allocation, cap].min
        end

        def share(dimension, amount, ordinal)
          return 0 unless SUPPORTED_DIMENSIONS.include?(dimension)
          return integer_share(amount, ordinal) if TOKEN_DIMENSIONS.include?(dimension) && amount.is_a?(Integer)

          decimal_share(amount)
        end

        def integer_share(amount, ordinal)
          quotient, remainder = amount.divmod(branch_count)
          quotient + (ordinal < remainder ? 1 : 0)
        end

        def decimal_share(amount)
          exact = Budget::DecimalContext.call { BigDecimal(amount.to_s) / branch_count }
          candidate = exact.to_f
          candidate = candidate.prev_float if BigDecimal(candidate.to_s) > exact
          candidate
        end
      end
    end
  end
end
