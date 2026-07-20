# frozen_string_literal: true

require_relative "../errors"
require_relative "process_local"

module Smith
  class Workflow
    class PreparedStepExecutionScope
      include ProcessLocal

      def initialize
        @mutex = Mutex.new
        @phase = :issued
        @thread = nil
        @fiber = nil
        @branch_fibers = {}.compare_by_identity
      end

      def activate!(thread, fiber = Fiber.current)
        Thread.handle_interrupt(Object => :never) do
          @mutex.synchronize do
            raise WorkflowError, "prepared-step execution scope is no longer available" unless @phase == :issued

            @phase = :active
            @thread = thread
            @fiber = fiber
          end
        end
      end

      def close!(thread = nil, fiber = Fiber.current)
        Thread.handle_interrupt(Object => :never) do
          @mutex.synchronize do
            if @phase == :active && thread && !owner?(@thread, @fiber, thread, fiber)
              raise WorkflowError, "prepared-step execution scope belongs to another thread or fiber"
            end
            raise WorkflowError, "prepared-step execution still has active branch fibers" unless @branch_fibers.empty?

            @phase = :closed
            @thread = nil
            @fiber = nil
          end
        end
      end

      def within_branch(&block)
        thread = Thread.current
        fiber = Fiber.current
        Thread.handle_interrupt(Object => :never) do
          enter_branch!(thread, fiber)
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            leave_branch!(thread, fiber)
          end
        end
      end

      def active_for?(thread, fiber = Fiber.current)
        @mutex.synchronize do
          @phase == :active && (owner?(@thread, @fiber, thread, fiber) || branch_owner?(thread, fiber))
        end
      end

      def binding_accessible_for?(thread, fiber = Fiber.current)
        @mutex.synchronize do
          @phase == :issued ||
            (@phase == :active && (owner?(@thread, @fiber, thread, fiber) || branch_owner?(thread, fiber)))
        end
      end

      private

      def enter_branch!(thread, fiber)
        @mutex.synchronize do
          raise WorkflowError, "prepared-step execution scope is not active" unless @phase == :active

          entry = @branch_fibers[fiber]
          if entry && !entry.fetch(:thread).equal?(thread)
            raise WorkflowError, "prepared-step branch fiber belongs to another thread"
          end

          @branch_fibers[fiber] = { thread:, count: entry ? entry.fetch(:count) + 1 : 1 }
        end
      end

      def leave_branch!(thread, fiber)
        @mutex.synchronize do
          entry = @branch_fibers.fetch(fiber) do
            raise WorkflowError, "prepared-step branch execution fiber is not active"
          end
          unless entry.fetch(:thread).equal?(thread)
            raise WorkflowError, "prepared-step branch fiber belongs to another thread"
          end

          count = entry.fetch(:count)
          count == 1 ? @branch_fibers.delete(fiber) : entry[:count] = count - 1
        end
      end

      def branch_owner?(thread, fiber)
        entry = @branch_fibers[fiber]
        !!(entry && entry.fetch(:thread).equal?(thread))
      end

      def owner?(owner_thread, owner_fiber, thread, fiber)
        owner_thread.equal?(thread) && owner_fiber.equal?(fiber)
      end
    end
  end
end
