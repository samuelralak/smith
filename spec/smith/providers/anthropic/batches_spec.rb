# frozen_string_literal: true

RSpec.describe Smith::Providers::Anthropic::Batches do
  let(:server) { SseServer.new }
  let(:config) do
    RubyLLM::Configuration.new.tap do |config|
      config.anthropic_api_key = "test-key"
      config.anthropic_api_base = server.url
      config.max_retries = 3
    end
  end
  let(:batches) { described_class.new(config:) }
  let(:request) { Smith::Batch.request(provider: "anthropic", params: { model: "m", max_tokens: 10, messages: [] }, headers: {}) }

  after { server.close }

  it "submits the queued requests as one batch, with their shared headers, and returns its id" do
    server.reply(json: { id: "msgbatch_1", processing_status: "in_progress" })
    beta = Smith::Batch.request(provider: "anthropic", params: { model: "m" }, headers: { "anthropic-beta" => "x-1" })

    expect(batches.submit([{ custom_id: "a" * 64, request: beta }, { "custom_id" => "b" * 64, "request" => beta }]))
      .to eq("msgbatch_1")
    sent = server.requests.sole
    expect([sent.verb, sent.path, sent.headers["anthropic-beta"], sent.headers["x-api-key"]])
      .to eq(["POST", "/v1/messages/batches", "x-1", "test-key"])
    expect(sent.body).to eq("requests" => [{ "custom_id" => "a" * 64, "params" => { "model" => "m" } },
                                           { "custom_id" => "b" * 64, "params" => { "model" => "m" } }])
    expect(config.max_retries).to eq(3)
  end

  it "refuses what one batch cannot take, before sending" do
    openai = Smith::Batch.request(provider: "openai", params: {}, headers: {})
    beta = Smith::Batch.request(provider: "anthropic", params: {}, headers: { "anthropic-beta" => "x" })

    expect { batches.submit([]) }.to raise_error(ArgumentError, /1 to 100000/)
    expect { batches.submit([{ custom_id: "a", request: openai }]) }.to raise_error(ArgumentError, /openai/)
    expect { batches.submit([{ custom_id: "a", request: }, { custom_id: "b", request: beta }]) }
      .to raise_error(ArgumentError, /share their headers/)
    stub_const("#{described_class}::MAX_REQUESTS", 1)
    expect { batches.submit([{ custom_id: "a", request: }, { custom_id: "b", request: }]) }
      .to raise_error(ArgumentError, /1 to 1 requests/)
    stub_const("#{described_class}::MAX_BYTES", 10)
    expect { batches.submit([{ custom_id: "a", request: }]) }.to raise_error(ArgumentError, /bytes/)
    expect(server.requests).to eq([])
  end

  def results_file
    [{ custom_id: "a", result: { type: "succeeded", message: { id: "msg" } } },
     { custom_id: "b", result: { type: "errored", error: { type: "error" } } }].map { JSON.generate(_1) }.join("\n")
  end

  it "reads a batch's status, its results file, and cancels it" do
    server.reply(json: { id: "msgbatch_1", processing_status: "ended", request_counts: { succeeded: 1, errored: 1 },
                         ended_at: "2026-10-11T10:00:00Z", expires_at: "2026-10-12T10:00:00Z" })
          .reply(text: "#{results_file}\n\n")
          .reply(json: { id: "msgbatch_1", processing_status: "canceling" })

    expect(batches.status("msgbatch_1"))
      .to eq(status: "ended", counts: { "succeeded" => 1, "errored" => 1 }, ended_at: "2026-10-11T10:00:00Z",
             expires_at: "2026-10-12T10:00:00Z")
    expect(batches.results("msgbatch_1").to_a)
      .to eq([["a", { "type" => "succeeded", "message" => { "id" => "msg" } }],
              ["b", { "type" => "errored", "error" => { "type" => "error" } }]])
    expect(batches.cancel("msgbatch_1")).to eq("canceling")
    expect(server.requests.map { [_1.verb, _1.path] })
      .to eq([%w[GET /v1/messages/batches/msgbatch_1], %w[GET /v1/messages/batches/msgbatch_1/results],
              %w[POST /v1/messages/batches/msgbatch_1/cancel]])
    expect { batches.status("../x") }.to raise_error(ArgumentError, /not a batch id/)
  end

  it "never sends a submit twice: the connection makes no retries" do
    server.reply(json: { error: { type: "overloaded_error", message: "busy" } }, status: "529 Overloaded")
          .reply(json: { id: "msgbatch_2" })

    expect { batches.submit([{ custom_id: "a", request: }]) }.to raise_error(RubyLLM::Error)
    expect(server.requests.length).to eq(1)
  end
end
