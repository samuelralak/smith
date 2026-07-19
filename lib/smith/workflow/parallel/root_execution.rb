# frozen_string_literal: true

require "concurrent"
require "dry-initializer"

module Smith
  class Workflow
    class Parallel
      class RootExecution
        extend Dry::Initializer

        option :branches

        def call
          Thread.handle_interrupt(Object => :never) do
            prepare
            values = Thread.handle_interrupt(Object => :immediate) { resolve(@futures) }
            @completed = true
            values
          rescue Exception => e # rubocop:disable Lint/RescueException
            @signal&.cancel!(e)
            raise
          ensure
            cleanup
          end
        end

        private

        def prepare
          @completed = false
          @signal = CancellationSignal.new
          @concurrency = Smith.config.parallel_concurrency
          @nesting_limit = Smith.config.parallel_nesting_limit
          @executor = build_executor
          @futures = build_futures(build_context)
        end

        def build_executor
          Concurrent::FixedThreadPool.new(
            @concurrency,
            max_queue: [@concurrency, branches.length].max,
            fallback_policy: :abort
          )
        end

        def build_context
          ExecutionContext.new(
            executor: @executor,
            signal: @signal,
            concurrency: @concurrency,
            nesting_limit: @nesting_limit,
            top_level_branch_count: branches.length
          )
        end

        def build_futures(context)
          branches.map { future_for(_1, context) }
        end

        def future_for(branch, context)
          Concurrent::Promises.future_on(context.executor, branch, context) do |callable, execution_context|
            execution_context.top_level_started!
            execution_context.raise_if_cancelled!
            execution_context.within(depth: 0) { callable.call(execution_context.signal) }
          rescue StandardError => e
            execution_context.signal.cancel!(e)
            raise
          ensure
            execution_context.top_level_finished!
          end
        end

        def resolve(futures)
          fulfilled, values, reasons = Concurrent::Promises.zip(*futures).result
          raise(@signal.reason || Parallel.preferred_error(reasons)) unless fulfilled

          values
        end

        def cleanup
          @signal&.cancel!(Cancellation.new("parallel execution interrupted")) unless @completed
          return unless @executor

          @executor.shutdown
          @executor.wait_for_termination
        end
      end
    end
  end
end
