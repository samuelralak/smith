# frozen_string_literal: true

# A provider's refusal for want of credit or past a spending limit is a
# RubyLLM::PaymentRequiredError whatever status it came with (0.12.4), so a
# host can have a step wait for credit instead of failing.
RSpec.describe "Smith billing refusals" do
  include_context "with a recording budget ledger"

  def anthropic_error(type, message, **details)
    { type: "error", error: { type:, message:, **({ details: } if details.any?).to_h } }
  end

  let(:low_credit) do
    anthropic_error("invalid_request_error", "Your credit balance is too low to access the Anthropic API. " \
                                             "Please go to Plans & Billing to upgrade or purchase credits.")
  end
  let(:usage_limit) do
    anthropic_error("invalid_request_error", "You have reached your specified workspace API usage limits. " \
                                             "You will regain access on 2026-11-01 at 00:00 UTC.")
  end
  let(:spend_cap) do
    anthropic_error("rate_limit_error", "You have reached your API usage limits: your organization has crossed " \
                                        "its monthly API usage threshold. You will regain access on 2026-11-01.",
                    error_code: "enforced_spend_limit_reached")
  end
  let(:bad_request) { anthropic_error("invalid_request_error", "messages: at least one message is required") }

  around do |example|
    saved = [Smith.config.interrupting_errors, Smith.config.stream_sinks]
    example.run
  ensure
    Smith.config.interrupting_errors, Smith.config.stream_sinks = saved
  end

  def failure(workflow) = workflow.to_state[:last_failed_step]

  def source(workflow) = failure(workflow).dig(:error_details, "source_error_class")

  def waits_for_credit
    Smith.config.interrupting_errors = [RubyLLM::PaymentRequiredError]
  end

  it "stops a step that meets one as an interruption when the host names RubyLLM::PaymentRequiredError" do
    waits_for_credit
    agent("SpecRefusalAgent")
    server.reply(json: low_credit, status: "400 Bad Request")
    workflow = asking("SpecRefusalWorkflow").new(context: {})

    expect { workflow.run! }.to raise_error(RubyLLM::PaymentRequiredError) do |error|
      expect(error.cause).to be_a(RubyLLM::BadRequestError)
    end
    expect([workflow.state, failure(workflow)]).to eq([:idle, nil])
  end

  it "fails a step whose host names none, with the refusal as its cause" do
    agent("SpecRefusalFailAgent")
    server.reply(json: usage_limit, status: "400 Bad Request")
    workflow = asking("SpecRefusalFailWorkflow").new(context: {})
    workflow.run!

    expect(workflow.state).to eq(:failed)
    expect(source(workflow)).to eq("RubyLLM::PaymentRequiredError")
  end

  it "takes Anthropic's monthly spend cap as one, though it comes as a rate limit" do
    waits_for_credit
    agent("SpecSpendCapAgent")
    server.reply(json: spend_cap, status: "429 Too Many Requests")

    expect { asking("SpecSpendCapWorkflow").new(context: {}).run! }.to raise_error(RubyLLM::PaymentRequiredError)
  end

  it "takes a streamed request's refusal as one, though RubyLLM takes it as a server error" do
    waits_for_credit
    sink = Class.new { %i[start delta reset finish fail].each { define_method(_1) { |*| nil } } }.new
    Smith.config.stream_sinks = { reply: ->(_info) { sink } }
    agent("SpecStreamedRefusalAgent")
    server.reply(json: low_credit, status: "400 Bad Request")
    workflow = asking("SpecStreamedRefusalWorkflow", stream: :reply).new(context: {})

    expect { workflow.run! }.to raise_error(RubyLLM::PaymentRequiredError) do |error|
      expect(error.cause).to be_a(RubyLLM::ServerError)
    end
    expect(server.requests.sole.body).to include("stream" => true)
  end

  it "takes OpenAI's spent quota as one, and a rate limit that speaks of a quota as a rate limit" do
    waits_for_credit
    agent("SpecQuotaAgent", model: "gpt-5", provider: :openai)
    quota = "You exceeded your current quota, please check your plan and billing details."
    server.reply(json: { error: { message: quota, type: "insufficient_quota", code: "insufficient_quota" } },
                 status: "429 Too Many Requests")

    expect { asking("SpecQuotaWorkflow").new(context: {}).run! }.to raise_error(RubyLLM::PaymentRequiredError)

    server.reply(json: { error: { code: 429, message: quota, status: "RESOURCE_EXHAUSTED" } },
                 status: "429 Too Many Requests")
    workflow = asking("SpecQuotaRateLimitWorkflow").new(context: {})
    workflow.run!

    expect(workflow.state).to eq(:failed)
  end

  it "leaves any other bad request as it is, one that quotes a refusal's words among them" do
    waits_for_credit
    agent("SpecBadRequestAgent")
    quoting = anthropic_error("invalid_request_error", "system: 'You have reached your specified API usage limits' " \
                                                       "is not a valid cache_control value")

    [bad_request, quoting].each do |reply|
      server.reply(json: reply, status: "400 Bad Request")
      workflow = asking("SpecBadRequestWorkflow").new(context: {})
      workflow.run!

      expect(workflow.state).to eq(:failed)
      expect(source(workflow)).to eq("RubyLLM::BadRequestError")
    end
  end

  it "keeps the wait when a fallback on another account then fails another way" do
    waits_for_credit
    agent("SpecFallbackRefusalAgent") { fallback_models model: "gpt-5", provider: :openai }
    server.reply(json: low_credit, status: "400 Bad Request")
    server.reply(json: { error: { message: "Invalid schema", type: "invalid_request_error" } },
                 status: "400 Bad Request")
    workflow = asking("SpecFallbackRefusalWorkflow").new(context: {})

    expect { workflow.run! }.to raise_error(RubyLLM::PaymentRequiredError)
    expect(server.requests.map(&:path)).to eq(%w[/v1/messages /v1/chat/completions])
    expect([workflow.state, failure(workflow)]).to eq([:idle, nil])
  end

  it "takes a batch submit's refusal as one, and any other error as it is" do
    batches = Smith::Providers::Anthropic::Batches.new
    request = Smith::Batch.request(provider: "anthropic", params: { model: "m" }, headers: {})
    server.reply(json: low_credit, status: "400 Bad Request")

    expect { batches.submit([{ custom_id: "a", request: }]) }.to raise_error(RubyLLM::PaymentRequiredError)

    server.reply(json: bad_request, status: "400 Bad Request")

    expect { batches.submit([{ custom_id: "a", request: }]) }.to raise_error(RubyLLM::BadRequestError)
  end
end
