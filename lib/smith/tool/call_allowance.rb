# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class CallAllowance
      EXHAUSTION_POLICIES = %i[raise complete].freeze

      def self.charge_legacy!(allowance)
        LegacyCallAllowance.charge!(allowance) { yield if block_given? }
      end

      def initialize(remaining, on_exhaustion: :raise)
        invalid = (remaining.is_a?(Integer) && remaining.negative?) ||
                  (!remaining.is_a?(Integer) && !remaining.is_a?(CallBudget))
        raise ArgumentError, "tool call allowance must be a non-negative integer" if invalid

        initialize_scope(CallBudget.coerce(remaining), on_exhaustion:, parent: nil)
      end

      def scope(budget, on_exhaustion: @on_exhaustion)
        self.class.allocate.tap do |allowance|
          allowance.__send__(:initialize_scope, CallBudget.coerce(budget), on_exhaustion:, parent: self)
        end
      end

      def charge!(tool_name = nil)
        batch = CallBatch.coerce(exact? ? [tool_name] : 1, exact: exact?)

        synchronize do
          Thread.handle_interrupt(Object => :never) do
            raise BudgetExceeded, "agent tool_calls budget exceeded" unless reservable?(batch)

            yield if block_given?
            consume!(batch)
          end
        end
      end

      def remaining
        synchronize { lineage.map { _1.__send__(:counter).remaining }.min }
      end

      def remaining_for(tool_name)
        name = canonical_tool_name(tool_name)
        synchronize do
          exact_scopes = lineage.select { _1.__send__(:budget).exact? }
          return nil if exact_scopes.empty?

          exact_scopes.map { _1.__send__(:counter).remaining_for(name) }.min
        end
      end

      def reserve_batch(tool_names_or_size, ledger: nil)
        batch = CallBatch.coerce(tool_names_or_size, exact: exact?)

        synchronize do
          Thread.handle_interrupt(Object => :never) do
            return unless reservable?(batch)

            workflow_ledger = ledger if ledger&.limits&.key?(:tool_calls)
            ledger_reservation = workflow_ledger&.reserve!(:tool_calls, batch.size)
            reservation = CallReservation.new(
              limit: batch.size,
              ledger: workflow_ledger,
              ledger_reservation: ledger_reservation
            )

            consume!(batch)
            reservation
          end
        end
      rescue BudgetExceeded
        nil
      end

      def complete_on_exhaustion?
        @on_exhaustion == :complete
      end

      def exact?
        lineage.any? { _1.__send__(:budget).exact? }
      end

      def used?
        synchronize { counter.used? }
      end

      def [](key)
        remaining if key == :remaining
      end

      protected

      attr_reader :budget

      private

      def initialize_scope(budget, on_exhaustion:, parent:)
        unless EXHAUSTION_POLICIES.include?(on_exhaustion)
          raise ArgumentError, "tool call exhaustion policy must be :raise or :complete"
        end

        @budget = budget
        @parent = parent
        @lineage = [self, *Array(parent&.__send__(:lineage))].freeze
        @mutex = parent ? parent.__send__(:shared_mutex) : Mutex.new
        @counter = CallAllowanceCounter.new(budget)
        @on_exhaustion = on_exhaustion
        self
      end

      attr_reader :lineage, :counter

      def shared_mutex = @mutex

      def synchronize(&) = @mutex.synchronize(&)

      def canonical_tool_name(value)
        name = value.to_s
        raise ArgumentError, "tool name must not be empty" if name.empty?

        name
      end

      def reservable?(batch)
        lineage.all? { _1.__send__(:counter).available?(batch) }
      end

      def consume!(batch)
        lineage.each { _1.__send__(:counter).consume!(batch) }
      end
    end
  end
end
