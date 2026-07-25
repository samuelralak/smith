# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class LegacyCallAllowance
      MUTEX = Mutex.new
      ALLOWANCE_MUTEXES = ObjectSpace::WeakMap.new
      private_constant :MUTEX, :ALLOWANCE_MUTEXES

      def self.charge!(allowance)
        allowance_mutex(allowance).synchronize do
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

      def self.reserve_batch(allowance, size, ledger: nil)
        allowance_mutex(allowance).synchronize do
          Thread.handle_interrupt(Object => :never) do
            reserve_synchronized(allowance, size, ledger)
          end
        end
      rescue BudgetExceeded
        nil
      end

      def self.allowance_mutex(allowance)
        MUTEX.synchronize { ALLOWANCE_MUTEXES[allowance] ||= Mutex.new }
      end
      private_class_method :allowance_mutex

      def self.reserve_synchronized(allowance, size, ledger)
        remaining = allowance[:remaining]
        return unless remaining.is_a?(Integer) && remaining >= size

        workflow_ledger = ledger if ledger&.limits&.key?(:tool_calls)
        ledger_reservation = workflow_ledger&.reserve!(:tool_calls, size)
        allowance[:remaining] = remaining - size
        CallReservation.new(
          limit: size,
          ledger: workflow_ledger,
          ledger_reservation:
        )
      end
      private_class_method :reserve_synchronized

      private_class_method :new
    end
  end
end
