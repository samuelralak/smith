# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    # A tool class's capture, inherited (Declarations) with its strictness: a
    # subclass's own `capture_result` replaces its parent's, block and
    # strictness together.
    module CaptureConfiguration
      def capture_result(strict: false, &block)
        return declared(:@capture_result) unless block

        raise ArgumentError, "capture_result strict must be true or false" unless [true, false].include?(strict)

        @capture_result_strict = strict
        @capture_result = block
      end

      def capture_result_strict?
        declaring_tool(:@capture_result)&.instance_variable_get(:@capture_result_strict) == true
      end
    end
  end
end
