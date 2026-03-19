# frozen_string_literal: true

module Smith
  module Trace
    SENSITIVITY_CONTENT_KEYS = %i[args result].freeze

    def self.record(type:, data:, sensitivity: :low)
      adapter = resolve_adapter
      return unless adapter

      filtered = apply_sensitivity(data, sensitivity)
      filtered = filter_fields(type, filtered)
      adapter.record(type: type, data: filtered)
    rescue StandardError => e
      Smith.config.logger&.error("Smith::Trace adapter error: #{e.message}")
    end

    def self.resolve_adapter
      configured = Smith.config.trace_adapter
      return nil unless configured

      if configured.is_a?(Class)
        @adapter_instances ||= {}
        @adapter_instances[configured] ||= configured.new
      else
        configured
      end
    end

    def self.reset!
      @adapter_instances = nil
    end

    def self.apply_sensitivity(data, sensitivity)
      case sensitivity
      when :high
        data.except(*SENSITIVITY_CONTENT_KEYS)
      when :medium
        redact_sensitive_keys(data)
      else
        data
      end
    end

    def self.redact_sensitive_keys(data)
      data.each_with_object({}) do |(key, value), filtered|
        filtered[key] = if SENSITIVITY_CONTENT_KEYS.include?(key)
                          redact_value(value)
                        else
                          value
                        end
      end
    end

    def self.redact_value(value)
      case value
      when String
        "[REDACTED]"
      when Hash
        value.transform_values { |v| v.is_a?(String) ? "[REDACTED]" : v }
      else
        value
      end
    end

    def self.filter_fields(type, data)
      configured_fields = Smith.config.trace_fields
      return data unless configured_fields.is_a?(Hash)

      allowed = configured_fields[type]
      return data unless allowed.respond_to?(:include?)

      data.each_with_object({}) do |(key, value), filtered|
        filtered[key] = value if allowed.include?(key)
      end
    end
  end
end
