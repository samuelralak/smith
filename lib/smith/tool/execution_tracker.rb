# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionTracker
      def initialize
        @started = false
        @mutex = Mutex.new
      end

      def mark_started!
        @mutex.synchronize { @started = true }
      end

      def started?
        @mutex.synchronize { @started }
      end
    end
  end
end
