# frozen_string_literal: true

module CoreInvisibility
  # Anthropic Messages replies as the local server sends them.
  module Replies
    module_function

    def message(text, id: "msg_1", tokens: [100, 20], stop: "end_turn", model: "claude-sonnet-5-5")
      { "id" => id, "type" => "message", "role" => "assistant", "model" => model,
        "content" => [{ "type" => "text", "text" => text }], "stop_reason" => stop,
        "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
    end

    def json(value, **) = message(JSON.generate(value), **)

    # A reply calling one tool.
    def calling(name, id:, input:, msg:, tokens: [10, 4])
      message(nil, id: msg, stop: "tool_use", tokens:)
        .merge("content" => [{ "type" => "tool_use", "id" => id, "name" => name, "input" => input }])
    end

    def overloaded = { "type" => "error", "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }

    def server_error = { "type" => "error", "error" => { "type" => "api_error", "message" => "Internal error" } }

    def streamed(texts, id:, tokens: [30, 7])
      deltas = texts.map do |text|
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: } }
      end
      usage = { input_tokens: tokens.first, output_tokens: 0 }
      [{ type: "message_start", message: { id:, model: "claude-sonnet-5-5", usage: } },
       { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }, *deltas,
       { type: "content_block_stop", index: 0 },
       { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: tokens.last } },
       { type: "message_stop" }]
    end

    def succeeded(text, **) = { "type" => "succeeded", "message" => message(text, **) }

    # OpenAI's image edits answer, the image as base64.
    def painted(bytes)
      usage = { "input_tokens" => 40, "input_tokens_details" => { "image_tokens" => 30, "text_tokens" => 10 },
                "output_tokens" => 823, "output_tokens_details" => { "image_tokens" => 823, "text_tokens" => 0 } }
      { "created" => 1, "data" => [{ "b64_json" => [bytes].pack("m0") }], "usage" => usage }
    end

    def throttled = { "error" => { "message" => "Slow down", "type" => "rate_limit_exceeded" } }

    # An image request the provider's safety system refused.
    def moderation_blocked
      { "error" => { "code" => "moderation_blocked", "type" => "image_generation_user_error",
                     "message" => "Your request was rejected by the safety system." } }
    end
  end
end
