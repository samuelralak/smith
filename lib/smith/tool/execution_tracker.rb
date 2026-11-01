# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    # What the tools of one step attempt did: whether any began, and whether
    # one that is not replay-safe did, which leaves the step's outcome
    # uncertain (nothing may run its tools again).
    class ExecutionTracker
      def initialize
        @started = false
        @uncertain = false
        @mutex = Mutex.new
      end

      def mark_started!(replay_safe: false)
        @mutex.synchronize do
          @started = true
          @uncertain = true unless replay_safe
        end
      end

      def started?
        @mutex.synchronize { @started }
      end

      def uncertain?
        @mutex.synchronize { @uncertain }
      end
    end
  end
end
