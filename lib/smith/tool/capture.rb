# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module Capture
      private

      def capture_result_if_configured(kwargs, result)
        block = self.class.capture_result
        return unless block

        collector = self.class.current_tool_result_collector
        return unless collector

        captured = block.call(kwargs, result)
        collector.call({ tool: name.to_s, captured: captured }) if captured
      rescue StandardError => e
        Smith.config.logger&.warn("[Smith] capture_result failed for #{name}: #{e.message}")
      end
    end
  end
end
