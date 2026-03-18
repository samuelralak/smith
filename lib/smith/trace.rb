# frozen_string_literal: true

module Smith
  module Trace
    def self.record(type:, data:)
      adapter = resolve_adapter
      return unless adapter

      adapter.record(type: type, data: data)
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
  end
end
