# frozen_string_literal: true

# A streamed step's chat sends each request once (0.12.5): RubyLLM's HTTP
# retries would read a failed stream's error body into a buffer the retry
# reuses, losing what the provider said, or stream the retry's text after
# the first's. Calls that do not stream keep RubyLLM's retries.
RSpec.describe "Smith streamed requests" do
  include_context "with a recording budget ledger"

  let(:sink_class) do
    Class.new do
      attr_reader :texts

      def initialize = @texts = []
      def start(_info) = nil
      def delta(text) = @texts << text
      def reset(_reason) = nil
      def finish(_output) = nil
      def fail(_error_class) = nil
    end
  end
  let(:sink) { sink_class.new }
  let(:low_credit) do
    { type: "error", error: { type: "invalid_request_error",
                              message: "Your credit balance is too low to access the Anthropic API." } }
  end

  around do |example|
    saved = [Smith.config.interrupting_errors, Smith.config.stream_sinks, RubyLLM.config.retry_interval]
    example.run
  ensure
    Smith.config.interrupting_errors, Smith.config.stream_sinks, RubyLLM.config.retry_interval = saved
  end

  before do
    RubyLLM.config.max_retries = 3
    RubyLLM.config.retry_interval = 0
    Smith.config.stream_sinks = { reply: ->(_info) { sink } }
  end

  def finished_round(text)
    [*text_round(text), { type: "content_block_stop", index: 0 },
     { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } },
     { type: "message_stop" }]
  end

  def text_round(*texts)
    [{ type: "message_start", message: { id: "msg_1", model: "m", usage: { input_tokens: 3, output_tokens: 0 } } },
     { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
     *texts.map { { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: _1 } } }]
  end

  it "takes a streamed refusal for want of credit as one, with RubyLLM's retries on, sending it once" do
    Smith.config.interrupting_errors = [RubyLLM::PaymentRequiredError]
    agent("SpecOnceRefusalAgent")
    server.reply(json: low_credit, status: "400 Bad Request")

    expect { asking("SpecOnceRefusalWorkflow", stream: :reply).new(context: {}).run! }
      .to raise_error(RubyLLM::PaymentRequiredError)
    expect(server.requests.size).to eq(1)
  end

  it "never sends again a stream that failed part way, so its text is never streamed twice" do
    agent("SpecOncePartAgent")
    error = JSON.generate(type: "error", error: { type: "overloaded_error", message: "Overloaded" })
    overloaded = "event: error\ndata: #{error}\n\n"
    server.reply(events: [*text_round("Hel"), overloaded])
    server.reply(events: finished_round("Hello"))
    workflow = asking("SpecOncePartWorkflow", stream: :reply).new(context: {})
    workflow.run!

    expect(workflow.state).to eq(:failed)
    expect([server.requests.size, sink.texts]).to eq([1, ["Hel"]])
  end

  it "keeps RubyLLM's retries for a call that does not stream" do
    agent("SpecRetriedAgent")
    server.reply(json: { type: "error", error: { type: "api_error", message: "Internal" } },
                 status: "500 Internal Server Error")
    server.reply(json: message("Hello"))
    workflow = asking("SpecRetriedWorkflow").new(context: {})
    workflow.run!

    expect([workflow.state, server.requests.size]).to eq([:done, 2])
  end

  it "keeps the agent's own config for a streamed call" do
    RubyLLM.config.anthropic_api_base = "http://127.0.0.1:9"
    own = RubyLLM.context { |config| config.anthropic_api_base = server.url }
    agent("SpecOwnContextAgent") { context own }
    server.reply(events: finished_round("Hi"))
    workflow = asking("SpecOwnContextWorkflow", stream: :reply).new(context: {})

    expect([workflow.run!.output, workflow.state]).to eq(["Hi", :done])
    expect([own.config.max_retries, RubyLLM.config.max_retries]).to eq([3, 3])
  end

  it "keeps what RubyLLM knows of a model it lists, its output limit and its thinking budget, when it streams" do
    Smith::Agent::Registry.delete(:spec_ledger_agent)
    with_stubbed_class("SpecKnownModelAgent", agent_class) do
      register_as :spec_ledger_agent
      model "claude-sonnet-4-5", provider: :anthropic
      thinking budget: 2048
    end
    server.reply(json: message("Plain"))
    server.reply(events: finished_round("Streamed"))
    asking("SpecKnownPlainWorkflow").new(context: {}).run!
    streamed = asking("SpecKnownStreamedWorkflow", stream: :reply).new(context: {})

    expect(streamed.run!.output).to eq("Streamed")
    plain, stream = server.requests.map(&:body)
    expect([stream["max_tokens"], stream["thinking"], stream["stream"]])
      .to eq([plain["max_tokens"], plain["thinking"], true])
    expect(plain["max_tokens"]).to be > 4096
  end

  it "keeps RubyLLM's retries for a request OpenAI's Responses route sends whole" do
    agent("SpecResponsesAgent", model: "gpt-5", provider: :openai) do
      params max_tokens: 500, openai_api_mode: "responses"
    end
    server.reply(json: { error: { message: "Internal", type: "server_error" } }, status: "500 Internal Server Error")
    server.reply(json: { id: "resp_1", model: "gpt-5", status: "completed", output_text: "Whole", output: [],
                         usage: { input_tokens: 3, output_tokens: 1 } })
    asking("SpecResponsesWorkflow", stream: :reply).new(context: {}).run!

    expect(server.requests.map(&:path)).to eq(%w[/v1/responses /v1/responses])
  end
end
