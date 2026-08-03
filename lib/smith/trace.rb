# frozen_string_literal: true

require_relative "attribution"

module Smith
  module Trace
    SENSITIVITY_CONTENT_KEYS = %i[args result].freeze
    ADAPTER_MUTEX = Mutex.new
    private_constant :ADAPTER_MUTEX

    def self.record(type:, data:, sensitivity: :low)
      adapter = resolve_adapter
      return unless adapter

      filtered = apply_content_policy(attributed(data), sensitivity)
      filtered = filter_fields(type, filtered)
      adapter.record(type: type, data: filtered)
    rescue StandardError => e
      Smith.config.logger&.error("Smith::Trace adapter error: #{e.message}")
    end

    # Ambient attribution keys are identifiers, not content: they merge in
    # under the caller's own keys (the caller wins on conflict) and then pass
    # through the same content policy and field allowlist as everything else,
    # so a host's configured trace_fields contract keeps holding.
    def self.attributed(data)
      return data unless Smith.config.trace_attribution

      fields = Attribution.current_fields
      return data if fields.empty?

      fields.merge(data)
    end

    # Class-configured adapters memoize one instance under a mutex so
    # concurrent first records (every fan-out branch emits) share a single
    # adapter instead of racing separate instances and losing entries.
    def self.resolve_adapter
      configured = Smith.config.trace_adapter
      return nil unless configured
      return configured unless configured.is_a?(Class)

      ADAPTER_MUTEX.synchronize do
        @adapter_instances ||= {}
        @adapter_instances[configured] ||= configured.new
      end
    end

    def self.reset!
      ADAPTER_MUTEX.synchronize { @adapter_instances = nil }
    end

    def self.apply_content_policy(data, sensitivity)
      case Smith.config.trace_content
      when true
        apply_sensitivity(data, sensitivity)
      when :redacted
        apply_sensitivity(redact_sensitive_keys(data), sensitivity)
      else
        data.except(*SENSITIVITY_CONTENT_KEYS)
      end
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
