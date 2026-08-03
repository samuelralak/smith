# frozen_string_literal: true

module Smith
  module Trace
    class OpenTelemetry
      CONFIG_MAP = {
        transition: :trace_transitions,
        tool_call: :trace_tool_calls,
        token_usage: :trace_token_usage,
        provider_call: :trace_provider_calls,
        cost: :trace_cost,
        normalizer_decision: :trace_normalizer
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

      # Smith trace events describe operations that already finished, so the
      # span is created retroactively: when the event carries a duration
      # (:tool_call seconds, :provider_call milliseconds) the span's start is
      # backdated by it and the span duration is real; otherwise the span is
      # an instant. Uses only the documented opentelemetry-api surface
      # (Tracer#start_span with start_timestamp, Span#finish with
      # end_timestamp) so any SDK the host installs applies.
      def record(type:, data:)
        return unless @tracer
        return unless type_enabled?(type)

        filtered = filter_content(data)
        finished_at = Time.now
        span = @tracer.start_span("smith.#{type}", start_timestamp: span_start(filtered, finished_at))
        begin
          apply_attributes(span, filtered)
        ensure
          span.finish(end_timestamp: finished_at)
        end
      end

      private

      def span_start(data, finished_at)
        seconds = duration_seconds(data)
        seconds ? finished_at - seconds : finished_at
      end

      def duration_seconds(data)
        return data[:duration].to_f if data[:duration].is_a?(Numeric)
        return data[:duration_ms] / 1000.0 if data[:duration_ms].is_a?(Numeric)

        nil
      end

      def apply_attributes(span, data)
        data.each do |key, value|
          coerced = attribute_value(value)
          span.set_attribute("smith.#{key}", coerced) unless coerced.nil?
        end
      end

      # OpenTelemetry attributes accept strings, integers, floats, and
      # booleans; numeric values keep their type instead of arriving as
      # strings, everything else (symbols included) becomes a string, nil
      # drops.
      def attribute_value(value)
        case value
        when String, Integer, Float, true, false then value
        when nil then nil
        else value.to_s
        end
      end

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
