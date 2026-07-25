# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class InvocationSequence
      def initialize(next_ordinal: 1)
        unless next_ordinal.is_a?(Integer) && next_ordinal.positive?
          raise ArgumentError, "next tool invocation ordinal must be positive"
        end

        @next_ordinal = next_ordinal
        @mutex = Mutex.new
      end

      def reserve(size)
        raise ArgumentError, "tool invocation batch size must be positive" unless size.is_a?(Integer) && size.positive?

        @mutex.synchronize do
          first = @next_ordinal
          @next_ordinal += size
          first
        end
      end
    end
  end
end
