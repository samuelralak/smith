# frozen_string_literal: true

require "bigdecimal"

module Smith
  module Budget
    class DecimalContext
      def self.call
        BigDecimal.save_limit do
          BigDecimal.limit(0)
          yield
        end
      end

      private_class_method :new
    end
  end
end
