# frozen_string_literal: true

# An error of a streamed request is what the provider said it was (0.12.6):
# RubyLLM guesses its status from the error event's type (Anthropic's adapter
# says 500 unless overloaded, OpenAI's 400 unless a server error or a rate
# limit).
RSpec.describe "Smith provider errors" do
  include_context "with a recording budget ledger"

  let(:sink) { Class.new { %i[start delta reset finish fail].each { define_method(_1) { |*| nil } } }.new }

  around do |example|
    saved = Smith.config.stream_sinks
    example.run
  ensure
    Smith.config.stream_sinks = saved
  end

  before { Smith.config.stream_sinks = { reply: ->(_info) { sink } } }

  # An error as RubyLLM raises it for a streamed request: its response one
  # RubyLLM built, headers and all.
  def streamed(kind, status, said)
    body = { "error" => said }
    env = Faraday::Env.from(status:, body:, response_headers: Faraday::Utils::Headers.new("retry-after" => "7"))
    kind.new(env, said["message"] || "guessed")
  end

  def anthropic(type, message = "said") = streamed(RubyLLM::ServerError, 500, { "type" => type, "message" => message })

  def openai(code, type = "invalid_request_error", kind: RubyLLM::BadRequestError, status: 400)
    streamed(kind, status, { "code" => code, "type" => type, "message" => "said" })
  end

  def finished_round(text)
    [{ type: "message_start", message: { id: "msg_1", model: "m", usage: { input_tokens: 3, output_tokens: 0 } } },
     { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
     { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: } },
     { type: "content_block_stop", index: 0 },
     { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } },
     { type: "message_stop" }]
  end

  it "fails a step whose streamed request was a bad request, sending it nowhere else" do
    agent("SpecStreamedBadAgent") { fallback_models "openai/gpt-5" }
    bad = { type: "error",
            error: { type: "invalid_request_error", message: "messages: at least one message is required" } }
    server.reply(json: bad, status: "400 Bad Request")
    workflow = asking("SpecStreamedBadWorkflow", stream: :reply).new(context: {})
    workflow.run!

    expect(workflow.state).to eq(:failed)
    expect(workflow.to_state[:last_failed_step].dig(:error_details, "source_error_class"))
      .to eq("RubyLLM::BadRequestError")
    expect(server.requests.size).to eq(1)
  end

  it "takes OpenAI's streamed wrong key as the account's, so the next provider answers" do
    agent("SpecStreamedKeyAgent", model: "gpt-5", provider: :openai) do
      fallback_models "anthropic/claude-sonnet-5-5"
    end
    wrong_key = { error: { message: "Incorrect API key provided", type: "invalid_request_error",
                           code: "invalid_api_key" } }
    server.reply(json: wrong_key, status: "401 Unauthorized")
    server.reply(events: finished_round("Answered"))
    workflow = asking("SpecStreamedKeyWorkflow", stream: :reply).new(context: {})

    expect(workflow.run!.output).to eq("Answered")
    expect(server.requests.map(&:path)).to eq(%w[/v1/chat/completions /v1/messages])
  end

  it "takes each type a provider names as the error RubyLLM raises for its status, its message and headers kept" do
    named = {
      anthropic("invalid_request_error") => [RubyLLM::BadRequestError, 400],
      anthropic("invalid_request_error", "prompt is too long: 250000 tokens") =>
        [RubyLLM::ContextLengthExceededError, 400],
      anthropic("authentication_error") => [RubyLLM::UnauthorizedError, 401],
      anthropic("billing_error") => [RubyLLM::PaymentRequiredError, 402],
      anthropic("permission_error") => [RubyLLM::ForbiddenError, 403],
      anthropic("not_found_error") => [RubyLLM::Error, 404],
      anthropic("request_too_large") => [RubyLLM::Error, 413],
      anthropic("rate_limit_error") => [RubyLLM::RateLimitError, 429],
      anthropic("timeout_error") => [RubyLLM::ServiceUnavailableError, 504],
      openai("invalid_api_key") => [RubyLLM::UnauthorizedError, 401],
      openai("unsupported_country_region_territory", "request_forbidden") => [RubyLLM::ForbiddenError, 403],
      openai("model_not_found") => [RubyLLM::Error, 404],
      openai("rate_limit_exceeded", "tokens") => [RubyLLM::RateLimitError, 429]
    }

    named.each do |error, (kind, status)|
      classified = Smith::ProviderErrors.classified(error)

      expect([classified.class, classified.response.status, classified.cause, classified.message])
        .to eq([kind, status, error, error.message])
      expect(classified.response.response_headers["retry-after"]).to eq("7")
    end
  end

  it "gives a type said without a message RubyLLM's words for its status, never the guess's" do
    unsaid = streamed(RubyLLM::ServerError, 500, { "type" => "authentication_error" })
    classified = Smith::ProviderErrors.classified(unsaid)

    expect(classified.message).to eq("Invalid API key - check your credentials")
  end

  it "leaves an error whose guess was right, whose body names nothing known, or that the provider sent whole" do
    whole = Faraday::Response.new(status: 403, body: { "error" => { "type" => "invalid_request_error" } })
    unchanged = [
      streamed(RubyLLM::OverloadedError, 529, { "type" => "overloaded_error" }),
      openai(nil),
      openai("rate_limit_exceeded", "requests", kind: RubyLLM::RateLimitError, status: 429),
      anthropic("api_error"),
      anthropic("something_new"),
      openai(nil, "server_error", kind: RubyLLM::ServerError, status: 500),
      openai("insufficient_quota", "insufficient_quota", kind: RubyLLM::RateLimitError, status: 429),
      RubyLLM::ServerError.new(Faraday::Env.from(status: 500, body: "<html>Bad gateway</html>"), "html"),
      RubyLLM::ForbiddenError.new(whole, "region")
    ]

    expect(unchanged.map { Smith::ProviderErrors.classified(_1) }).to eq(unchanged)
  end
end
