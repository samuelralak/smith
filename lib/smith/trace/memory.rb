# frozen_string_literal: true

module Smith
  module Trace
    class Memory
      CONFIG_MAP = {
        transition: :trace_transitions,
        tool_call: :trace_tool_calls,
        token_usage: :trace_token_usage,
        cost: :trace_cost
      }.freeze

      CONTENT_KEYS = %i[content prompt response args result].freeze

      attr_reader :traces

      def initialize
        @traces = []
      end

      def record(type:, data:)
        return unless type_enabled?(type)

        @traces << { type: type, data: filter_content(data) }
      end

      def clear!
        @traces = []
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
