# frozen_string_literal: true

module Smith
  module Trace
    class Logger
      CONFIG_MAP = {
        transition: :trace_transitions,
        tool_call: :trace_tool_calls,
        token_usage: :trace_token_usage,
        cost: :trace_cost
      }.freeze

      CONTENT_KEYS = %i[content prompt response args result].freeze

      def record(type:, data:)
        return unless type_enabled?(type)

        logger = Smith.config.logger
        return unless logger

        logger.info("[Smith::Trace] #{type}: #{filter_content(data).inspect}")
      end

      private

      def type_enabled?(type)
        config_key = CONFIG_MAP[type]
        return true unless config_key

        Smith.config.send(config_key) != false
      end

      def filter_content(data)
        case Smith.config.trace_content
        when true
          data
        when :redacted
          data.transform_values { |v| v.is_a?(String) ? "[REDACTED]" : v }
        else
          data.except(*CONTENT_KEYS)
        end
      end
    end
  end
end
