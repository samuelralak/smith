# frozen_string_literal: true

require_relative "../errors"

module Smith
  class Workflow
    class PreparedStepExecutionScope
      def initialize
        @mutex = Mutex.new
        @phase = :issued
        @thread = nil
      end

      def activate!(thread)
        @mutex.synchronize do
          raise WorkflowError, "prepared-step execution scope is no longer available" unless @phase == :issued

          @phase = :active
          @thread = thread
        end
      end

      def close!(thread = nil)
        @mutex.synchronize do
          if @phase == :active && thread && !@thread.equal?(thread)
            raise WorkflowError, "prepared-step execution scope belongs to another thread"
          end

          @phase = :closed
          @thread = nil
        end
      end

      def active_for?(thread)
        @mutex.synchronize { @phase == :active && @thread.equal?(thread) }
      end

      def binding_accessible_for?(thread)
        @mutex.synchronize do
          @phase == :issued || (@phase == :active && @thread.equal?(thread))
        end
      end
    end
  end
end
