# frozen_string_literal: true

require "dry-initializer"
require "json"

require_relative "../diagnostic_text"
require_relative "message_value_normalizer"

module Smith
  class Workflow
    class FailureDetailSnapshot
      OMITTED_KEY = "smith_failure_details_omitted"
      OMITTED_REASON_BYTES = 1_024
      private_constant :OMITTED_KEY, :OMITTED_REASON_BYTES

      extend Dry::Initializer

      param :value

      def call
        return if value.nil?

        snapshot = MessageValueNormalizer.new(value, label: "workflow failure details").call
        JSON.generate(snapshot)
        snapshot
      rescue StandardError => e
        {
          OMITTED_KEY => DiagnosticText.capture(e.message, max_bytes: OMITTED_REASON_BYTES)
        }.freeze
      end
    end
  end
end
