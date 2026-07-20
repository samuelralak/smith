# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class CallAllowance
      LEGACY_MUTEX = Mutex.new
      LEGACY_ALLOWANCE_MUTEXES = ObjectSpace::WeakMap.new
      private_constant :LEGACY_MUTEX
      private_constant :LEGACY_ALLOWANCE_MUTEXES

      def self.charge_legacy!(allowance)
        legacy_allowance_mutex(allowance).synchronize do
          Thread.handle_interrupt(Object => :never) do
            remaining = allowance[:remaining]
            unless remaining.is_a?(Integer) && remaining.positive?
              raise BudgetExceeded, "agent tool_calls budget exceeded"
            end

            yield if block_given?
            allowance[:remaining] = remaining - 1
          end
        end
      end

      def self.legacy_allowance_mutex(allowance)
        LEGACY_MUTEX.synchronize do
          LEGACY_ALLOWANCE_MUTEXES[allowance] ||= Mutex.new
        end
      end
      private_class_method :legacy_allowance_mutex

      def initialize(remaining)
        unless remaining.is_a?(Integer) && remaining >= 0
          raise ArgumentError, "tool call allowance must be a non-negative integer"
        end

        @remaining = remaining
        @mutex = Mutex.new
      end

      def charge!
        @mutex.synchronize do
          Thread.handle_interrupt(Object => :never) do
            raise BudgetExceeded, "agent tool_calls budget exceeded" unless @remaining.positive?

            yield if block_given?
            @remaining -= 1
          end
        end
      end

      def remaining
        @mutex.synchronize { @remaining }
      end

      def [](key)
        remaining if key == :remaining
      end
    end
  end
end
