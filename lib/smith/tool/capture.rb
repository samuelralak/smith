# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module Capture
      CAPTURE_FAILED = Object.new.freeze
      private_constant :CAPTURE_FAILED

      private

      def ensure_capture_ready!
        return unless self.class.capture_result && self.class.capture_result_strict?

        capture_collector(true)
      end

      def capture_result_if_configured(kwargs, result)
        block = self.class.capture_result
        return unless block

        capture_with_policy(block, kwargs, result, self.class.capture_result_strict?)
      end

      def capture_with_policy(block, kwargs, result, strict)
        collector = capture_collector(strict)
        return unless collector

        captured = captured_value(block, kwargs, result, strict)
        return if captured.equal?(CAPTURE_FAILED)

        append_capture(collector, captured, strict)
      end

      def capture_collector(strict)
        collector = self.class.current_tool_result_collector
        return collector unless strict
        return collector if collector.respond_to?(:call)

        reason = collector.nil? ? :collector_missing : :collector_invalid
        raise tool_capture_failed(reason)
      end

      def captured_value(block, kwargs, result, strict)
        captured = call_capture_block(block, kwargs, result, strict)
        return captured if captured.equal?(CAPTURE_FAILED)
        return captured unless captured.nil? && strict

        raise tool_capture_failed(:capture_empty)
      end

      def call_capture_block(block, kwargs, result, strict)
        block.call(kwargs, result)
      rescue StandardError => e
        capture_failure(e, strict, reason: :capture_block_failed)
      end

      def append_capture(collector, captured, strict)
        collector.call({ tool: name.to_s, captured: captured }) if strict || captured
      rescue StandardError => e
        capture_failure(e, strict, reason: :collector_failed)
      end

      def capture_failure(error, strict, reason:)
        return CAPTURE_FAILED.tap { log_capture_failure(error) } unless strict

        raise tool_capture_failed(reason), cause: error
      end

      def tool_capture_failed(reason)
        ToolCaptureFailed.for_runtime(tool_name: name, reason:)
      end

      def log_capture_failure(error)
        Smith.config.logger&.warn("[Smith] capture_result failed for #{name}: #{error.message}")
      end
    end
  end
end
