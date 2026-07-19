# frozen_string_literal: true

require "concurrent"
require "dry-initializer"

module Smith
  class Workflow
    class Parallel
      class NestedExecution
        extend Dry::Initializer

        option :branches
        option :context

        def initialize(...)
          super
          @depth = context.next_nesting_depth!
        end

        def call
          Thread.handle_interrupt(Object => :never) do
            prepare
            Thread.handle_interrupt(Object => :immediate) { execute }
          rescue Exception => e # rubocop:disable Lint/RescueException
            context.signal.cancel!(e)
            raise
          ensure
            drain_futures
            release_workers
          end
        end

        private

        def prepare
          context.raise_if_cancelled!
          @reserved_workers = context.reserve_workers(branches.length - 1)
          return if @reserved_workers.zero?

          @values = Array.new(branches.length)
          @cursor = Concurrent::AtomicFixnum.new(0)
          @futures = []
          @reserved_workers.times { @futures << build_future }
        end

        def execute
          return execute_inline if @reserved_workers.zero?

          execute_concurrently
        end

        def execute_concurrently
          fulfilled, reasons = execute_workers
          raise_worker_failure!(fulfilled, reasons)
          @values
        end

        def execute_workers
          current_error = capture_error { work }
          fulfilled, _values, reasons = Concurrent::Promises.zip(*@futures).result
          [fulfilled, [context.signal.reason, current_error, *reasons]]
        end

        def raise_worker_failure!(fulfilled, reasons)
          error = Parallel.preferred_error(reasons)
          raise(error || Cancellation.new("parallel execution failed")) unless fulfilled && !error
        end

        def build_future
          Concurrent::Promises.future_on(context.executor, context, @depth) do |execution_context, depth|
            execution_context.within(depth:) { work }
          end
        end

        def work
          while (index = next_index)
            @values[index] = execute_branch(index)
          end
        rescue StandardError => e
          context.signal.cancel!(e)
          raise
        end

        def next_index
          context.raise_if_cancelled!
          index = @cursor.increment - 1
          return if index >= branches.length

          context.raise_if_cancelled!
          index
        end

        def execute_branch(index)
          context.within(depth: @depth) { branches.fetch(index).call(context.signal) }
        end

        def execute_inline
          branches.map do |branch|
            context.raise_if_cancelled!
            context.within(depth: @depth) { branch.call(context.signal) }
          end
        rescue StandardError => e
          context.signal.cancel!(e)
          raise
        end

        def capture_error
          yield
          nil
        rescue StandardError => e
          e
        end

        def drain_futures
          Concurrent::Promises.zip(*@futures).result if @futures&.any?
        end

        def release_workers
          context.release_workers(@reserved_workers) if @reserved_workers&.positive?
        end
      end
    end
  end
end
