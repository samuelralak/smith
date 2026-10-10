# frozen_string_literal: true

require_relative "../diagnostic_text"

module Smith
  class Agent
    # The stop reason and the provider's own message id for one provider
    # response, read from the raw response body RubyLLM keeps on the message:
    # Anthropic Messages (`stop_reason`, `id`), OpenAI Chat Completions
    # (`choices[0].finish_reason`, `id`), and OpenAI Responses
    # (`incomplete_details.reason`, else `status`, and `id`). Both are
    # metadata: bounded Strings, absent when the response does not carry
    # them (streamed responses keep no raw body).
    module ProviderResponseFacts
      MAX_BYTES = 256

      module_function

      def from_message(message)
        body = raw_body(message)
        return {} unless body.is_a?(Hash)

        { stop_reason: bounded(stop_reason(body)), provider_message_id: bounded(body["id"]) }.compact
      end

      def raw_body(message)
        return unless message.respond_to?(:raw)

        raw = message.raw
        raw.respond_to?(:body) ? raw.body : raw
      rescue StandardError
        nil
      end

      def stop_reason(body)
        body["stop_reason"] || first_choice_finish_reason(body) ||
          body.dig("incomplete_details", "reason") || body["status"]
      rescue TypeError
        nil
      end

      def first_choice_finish_reason(body)
        choices = body["choices"]
        return unless choices.is_a?(Array) && choices.first.is_a?(Hash)

        choices.first["finish_reason"]
      end

      def bounded(value)
        return unless value.is_a?(String) && !value.empty?

        DiagnosticText.capture(value, max_bytes: MAX_BYTES)
      end
    end
  end
end
