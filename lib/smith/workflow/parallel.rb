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

      def self.resolve_branch_count(transition, context)
        count = transition.agent_opts[:count]
        count.respond_to?(:call) ? count.call(context) : (count || 1)
      end

      def self.execute(branches:)
        signal = CancellationSignal.new

        futures = branches.map do |branch|
          Concurrent::Promises.future(branch, signal) do |b, s|
            b.call(s)
          rescue StandardError
            s.cancel!
            raise
          end
        end

        fulfilled, values, reasons = Concurrent::Promises.zip(*futures).result

        unless fulfilled
          error = reasons.compact.first
          raise error
        end

        values
      end
    end
  end
end
