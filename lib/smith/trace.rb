# frozen_string_literal: true

module Smith
  module Trace
    def self.record(type:, data:)
      adapter = resolve_adapter
      return unless adapter

      adapter.record(type: type, data: filter_fields(type, data))
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
