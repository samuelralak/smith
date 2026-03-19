# frozen_string_literal: true

module Smith
  module Trace
    class OpenTelemetry
      CONFIG_MAP = {
        transition: :trace_transitions,
        tool_call: :trace_tool_calls,
        token_usage: :trace_token_usage,
        cost: :trace_cost
      }.freeze

      CONTENT_KEYS = %i[content prompt response args result].freeze

      def initialize
        require "opentelemetry-api"
        @tracer = ::OpenTelemetry.tracer_provider.tracer("smith", Smith::VERSION)
      rescue LoadError
        @tracer = nil
        Smith.config.logger&.warn(
          "Smith::Trace::OpenTelemetry requires the opentelemetry-api gem. " \
          "Add it to your Gemfile to enable OpenTelemetry tracing."
        )
      end

      def record(type:, data:)
        return unless @tracer
        return unless type_enabled?(type)

        filtered = filter_content(data)
        @tracer.in_span("smith.#{type}") do |span|
          filtered.each { |key, value| span.set_attribute("smith.#{key}", value.to_s) }
        end
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
