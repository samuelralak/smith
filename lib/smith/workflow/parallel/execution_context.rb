# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Parallel
      class ExecutionContext
        extend Dry::Initializer

        THREAD_KEY = :smith_parallel_execution_context
        DEPTH_KEY = :smith_parallel_execution_depth

        option :executor
        option :signal
        option :concurrency
        option :nesting_limit
        option :top_level_branch_count

        def initialize(...)
          super
          @pending_top_level = top_level_branch_count
          @active_top_level = 0
          @reserved_nested_workers = 0
          @mutex = Mutex.new
        end

        def self.current
          Fiber[THREAD_KEY]
        end

        def self.current_depth
          Fiber[DEPTH_KEY] || 0
        end

        def within(depth: self.class.current_depth)
          previous = self.class.current
          previous_depth = Fiber[DEPTH_KEY]
          Fiber[THREAD_KEY] = self
          Fiber[DEPTH_KEY] = depth
          yield
        ensure
          Fiber[THREAD_KEY] = previous
          Fiber[DEPTH_KEY] = previous_depth
        end

        def raise_if_cancelled!
          raise(signal.reason || Cancellation.new("cancelled")) if signal.cancelled?
        end

        def next_nesting_depth!
          depth = self.class.current_depth + 1
          return depth if depth <= nesting_limit

          raise WorkflowError, "parallel nesting exceeds configured limit #{nesting_limit}"
        end

        def top_level_started!
          @mutex.synchronize do
            @pending_top_level -= 1
            @active_top_level += 1
            validate_worker_count!
          end
        end

        def top_level_finished!
          @mutex.synchronize do
            @active_top_level -= 1
            validate_worker_count!
          end
        end

        def reserve_workers(requested)
          @mutex.synchronize do
            reserved = [requested, available_workers].min
            @reserved_nested_workers += reserved
            validate_worker_count!
            reserved
          end
        end

        def release_workers(count)
          @mutex.synchronize do
            @reserved_nested_workers -= count
            validate_worker_count!
          end
        end

        private

        def validate_worker_count!
          valid = @pending_top_level >= 0 && @active_top_level >= 0 && @reserved_nested_workers >= 0
          return if valid && occupied_workers <= concurrency

          raise WorkflowError, "parallel worker accounting exceeded its concurrency bound"
        end

        def available_workers
          concurrency - occupied_workers
        end

        def occupied_workers
          @active_top_level + reserved_top_level_workers + @reserved_nested_workers
        end

        def reserved_top_level_workers
          capacity = [concurrency - @active_top_level - @reserved_nested_workers, 0].max
          [@pending_top_level, capacity].min
        end
      end
    end
  end
end
