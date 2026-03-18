# frozen_string_literal: true

require "concurrent"

module Smith
  class Workflow
    class Parallel
      CancellationSignal = Struct.new(:cancelled, :mutex) do
        def initialize
          super(false, Mutex.new)
        end

        def cancel!
          mutex.synchronize { self.cancelled = true }
        end

        def cancelled?
          mutex.synchronize { cancelled }
        end
      end

      def self.execute(branches:)
        signal = CancellationSignal.new
        first_error = Concurrent::AtomicReference.new(nil)

        futures = branches.map do |branch|
          Concurrent::Future.execute do
            branch.call(signal)
          rescue StandardError => e
            first_error.compare_and_set(nil, e)
            signal.cancel!
            raise
          end
        end

        futures.each(&:wait)

        error = first_error.value
        raise error if error

        futures.map(&:value)
      end
    end
  end
end
