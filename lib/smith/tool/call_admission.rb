# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class CallAdmission
      THREAD_KEY = :smith_tool_call_admission
      private_constant :THREAD_KEY

      def self.current
        Thread.current[THREAD_KEY]
      end

      def self.around(admission, &block)
        raise ArgumentError, "block required" unless block

        previous = current
        Thread.handle_interrupt(Object => :never) do
          Thread.current[THREAD_KEY] = admission
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end
      end

      def initialize(tool:, reservation:)
        @tool = tool
        @reservation = reservation
        @available = true
        @mutex = Mutex.new
      end

      def claim(tool)
        @mutex.synchronize do
          return false unless @available && @tool.equal?(tool)

          @available = false
          @reservation.claim
        end
      end
    end
  end
end
