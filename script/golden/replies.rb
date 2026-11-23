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

    # `stop`: nil for a stream that ends without saying why.
    def streamed(texts, id:, tokens: [30, 7], stop: "end_turn")
      deltas = texts.map do |text|
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: } }
      end
      usage = { input_tokens: tokens.first, output_tokens: 0 }
      [{ type: "message_start", message: { id:, model: "claude-sonnet-5-5", usage: } },
       { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }, *deltas,
       { type: "content_block_stop", index: 0 },
       { type: "message_delta", delta: { stop_reason: stop }, usage: { output_tokens: tokens.last } },
       { type: "message_stop" }]
    end

    def succeeded(text, **) = { "type" => "succeeded", "message" => message(text, **) }

    # OpenAI's Chat Completions answer; `tokens`: prompt, completion and the
    # reasoning inside it.
    def completion(text, id:, model:, tokens: [10, 2, 0])
      prompt, completion, reasoning = tokens
      { "id" => id, "object" => "chat.completion", "model" => model,
        "choices" => [{ "index" => 0, "message" => { "role" => "assistant", "content" => text },
                        "finish_reason" => "stop" }],
        "usage" => { "prompt_tokens" => prompt, "completion_tokens" => completion,
                     "completion_tokens_details" => { "reasoning_tokens" => reasoning } } }
    end

    # OpenAI's image edits answer, the image as base64.
    def painted(bytes)
      usage = { "input_tokens" => 40, "input_tokens_details" => { "image_tokens" => 30, "text_tokens" => 10 },
                "output_tokens" => 823, "output_tokens_details" => { "image_tokens" => 823, "text_tokens" => 0 } }
      { "created" => 1, "data" => [{ "b64_json" => [bytes].pack("m0") }], "usage" => usage }
    end

    def throttled = { "error" => { "message" => "Slow down", "type" => "rate_limit_exceeded" } }

    # Anthropic's monthly spend cap, which it sends as a 429 rate limit.
    def spend_capped
      { "type" => "error",
        "error" => { "type" => "rate_limit_error",
                     "message" => "You have reached your API usage limits: your organization has crossed its " \
                                  "monthly API usage threshold.",
                     "details" => { "error_code" => "enforced_spend_limit_reached" } } }
    end

    # `reply` reporting `counts` beside its usage.
    def with_usage(reply, **counts) = reply.merge("usage" => reply["usage"].merge(counts.transform_keys(&:to_s)))

    # An image request the provider's safety system refused.
    def moderation_blocked
      { "error" => { "code" => "moderation_blocked", "type" => "image_generation_user_error",
                     "message" => "Your request was rejected by the safety system." } }
    end
  end
end
