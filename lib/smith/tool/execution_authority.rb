# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionAuthority
      THREAD_KEY = :smith_tool_execution_authority
      private_constant :THREAD_KEY

      def self.current = Thread.current[THREAD_KEY]

      def self.around(tool:, dispatch_claim:, &block)
        raise ArgumentError, "block required" unless block

        previous = current
        Thread.handle_interrupt(Object => :never) do
          Thread.current[THREAD_KEY] = new(tool:, dispatch_claim:)
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end
      end

      def initialize(tool:, dispatch_claim:)
        @tool = tool
        @dispatch_claim = dispatch_claim
        @available = true
        @mutex = Mutex.new
      end

      def claim(tool, dispatch_claim)
        @mutex.synchronize do
          return false unless @available && @tool.equal?(tool) && @dispatch_claim.equal?(dispatch_claim)

          @available = false
          true
        end
      end
    end
  end
end
