# frozen_string_literal: true

module Smith
  module Budget
    class Ledger
      attr_reader :limits

      def initialize(limits: {})
        @mutex = Mutex.new
        @limits = limits
        @consumed = Hash.new(0)
        @reserved = Hash.new(0)
      end

      def reserve!(key, amount)
        @mutex.synchronize do
          committed = @consumed[key] + @reserved[key]
          raise BudgetExceeded if committed + amount > @limits[key]

          @reserved[key] += amount
        end
      end

      def reconcile!(key, reserved_amount, actual_amount)
        @mutex.synchronize do
          @reserved[key] = [0, @reserved[key] - reserved_amount].max
          @consumed[key] += actual_amount
        end
      end

      def release!(key, amount)
        @mutex.synchronize do
          @reserved[key] = [0, @reserved[key] - amount].max
        end
      end

      def remaining(key)
        @mutex.synchronize { [@limits[key] - @consumed[key] - @reserved[key], 0].max }
      end
    end
  end
end
