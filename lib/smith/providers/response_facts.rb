# frozen_string_literal: true

require_relative "../diagnostic_text"

module Smith
  module Providers
    # The stop reason and the provider's own message id of one provider
    # response, read from the raw body RubyLLM keeps on the message. Each
    # provider's body is recognized by its own marker, never guessed from
    # loose field names:
    #
    #   Anthropic Messages      "type" => "message"          stop_reason, id
    #   OpenAI Chat Completions "object" => "chat.completion" choices[0].finish_reason, id
    #   OpenAI Responses        "object" => "response"       incomplete_details.reason, else status; id
    #   Gemini                  "candidates" => [...]         candidates[0].finishReason, responseId
    #   Bedrock Converse        "stopReason" => String        stopReason
    #
    # OpenAI reports a refusal on the message rather than as a finish
    # reason (Chat Completions `message.refusal`, a Responses `refusal`
    # content item); it is read as the stop reason "refusal". Gemini blocks a
    # prompt with `promptFeedback.blockReason` and no candidates; that is read
    # as the stop reason "prompt_blocked".
    #
    # Both facts are metadata: bounded Strings, absent when the body is of
    # none of these shapes, does not carry them, or cannot be read (streamed
    # responses keep no raw body). Reading never raises.
    module ResponseFacts
      MAX_BYTES = 256
      REFUSAL = "refusal"
      PROMPT_BLOCKED = "prompt_blocked"

      KEPT = "smith.response"
      # A response Smith made or kept itself (a response memo's, a test
      # stub's) carries its facts as a raw body of this shape.
      Kept = Struct.new(:body)

      READERS = [
        [->(body) { body["object"] == KEPT }, ->(body) { [body["stop_reason"], body["id"]] }],
        [->(body) { body["type"] == "message" }, ->(body) { [body["stop_reason"], body["id"]] }],
        [->(body) { body["object"] == "chat.completion" },
         lambda do |body|
           choice = first_entry(body["choices"])
           [(REFUSAL if chat_refusal?(choice)) || choice&.fetch("finish_reason", nil), body["id"]]
         end],
        [->(body) { body["object"] == "response" },
         lambda do |body|
           details = body["incomplete_details"]
           reason = (REFUSAL if responses_refusal?(body["output"])) || (details["reason"] if details.is_a?(Hash))
           [reason || body["status"], body["id"]]
         end],
        [->(body) { !body.key?("candidates") && body.dig("promptFeedback", "blockReason").is_a?(String) },
         ->(body) { [PROMPT_BLOCKED, body["responseId"]] }],
        [->(body) { body["candidates"].is_a?(Array) },
         ->(body) { [first_entry(body["candidates"])&.fetch("finishReason", nil), body["responseId"]] }],
        [->(body) { body["stopReason"].is_a?(String) }, ->(body) { [body["stopReason"], nil] }]
      ].freeze
      private_constant :READERS

      module_function

      def kept(stop_reason:, id:) = Kept.new({ "object" => KEPT, "stop_reason" => stop_reason, "id" => id })

      def from_message(message)
        body = raw_body(message)
        return {} unless body.instance_of?(Hash)

        _, reader = READERS.find { |(matches, _)| matches.call(body) }
        return {} unless reader

        stop_reason, message_id = reader.call(body)
        { stop_reason: bounded(stop_reason), provider_message_id: bounded(message_id) }.compact
      rescue StandardError
        {}
      end

      def raw_body(message)
        return unless message.respond_to?(:raw)

        raw = message.raw
        raw.respond_to?(:body) ? raw.body : raw
      end

      def chat_refusal?(choice)
        message = choice&.fetch("message", nil)
        message.is_a?(Hash) && message["refusal"].is_a?(String) && !message["refusal"].empty?
      end

      def responses_refusal?(output)
        return false unless output.is_a?(Array)

        output.any? do |item|
          item.is_a?(Hash) && item["content"].is_a?(Array) &&
            item["content"].any? { |part| part.is_a?(Hash) && part["type"] == REFUSAL }
        end
      end

      def first_entry(list)
        list.first if list.is_a?(Array) && list.first.is_a?(Hash)
      end

      def bounded(value)
        return unless value.is_a?(String) && !value.empty?

        DiagnosticText.capture(value, max_bytes: MAX_BYTES)
      end
    end
  end
end
