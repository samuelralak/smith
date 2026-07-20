# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module CaptureConfiguration
      def capture_result(strict: false, &block)
        return @capture_result unless block

        raise ArgumentError, "capture_result strict must be true or false" unless [true, false].include?(strict)

        @capture_result_strict = strict
        @capture_result = block
      end

      def capture_result_strict?
        @capture_result_strict == true
      end
    end
  end
end
