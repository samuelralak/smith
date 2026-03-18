# frozen_string_literal: true

module Smith
  module Trace
    def self.record(type:, data:)
      adapter = Smith.config.trace_adapter
      return unless adapter

      adapter.record(type: type, data: data)
    rescue StandardError => e
      Smith.config.logger&.error("Smith::Trace adapter error: #{e.message}")
    end
  end
end
