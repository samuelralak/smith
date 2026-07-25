# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class CallReservation
      extend Dry::Initializer

      option :limit
      option :ledger
      option :ledger_reservation

      def initialize(...)
        super
        @claimed = 0
        @settled = false
        @mutex = Mutex.new
      end

      def claim
        @mutex.synchronize do
          return false if @settled || @claimed >= limit

          @claimed += 1
          true
        end
      end

      def settle!
        Thread.handle_interrupt(Exception => :never) do
          @mutex.synchronize do
            return if @settled

            ledger&.reconcile!(ledger_reservation, @claimed)
            @settled = true
          end
        end
      end
    end
  end
end
