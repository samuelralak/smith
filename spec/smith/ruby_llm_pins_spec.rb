# frozen_string_literal: true

require "json"
require "smith/testing"

# What Smith does on RubyLLM 1.16 where moving to RubyLLM 2.x changes it
# without an error (the upgrade review's silent changes), pinned before the
# dependency moves. Each example drives a real step through RubyLLM's own
# provider code against the local stand-in server (spec/support/
# sse_server.rb) and states what Smith does, not how RubyLLM names it, so it
# turns red when the dependency changes under it and green again once the
# slice that moves its touchpoint lands. Every RubyLLM name or fact the
# examples rely on is marked "RubyLLM touchpoint", beside the provider setup
# of the shared ledger context (spec/support/budget_ledger_context.rb).
RSpec.describe "Smith on RubyLLM: behaviour pinned before the 2.x move" do
  include_context "with a recording budget ledger"

  let(:rates) do
    { input_cost_per_token: 0.000002, output_cost_per_token: 0.00001, cache_read_cost_per_token: 0.0000001,
      cache_write_cost_per_token: 0.0000025 }
  end
  let(:usage) do
    { "input_tokens" => 100, "output_tokens" => 20, "cache_read_input_tokens" => 4_000,
      "cache_creation_input_tokens" => 500, "output_tokens_details" => { "thinking_tokens" => 12 } }
  end
  let(:spent) { (100 * 0.000002) + (20 * 0.00001) + (4_000 * 0.0000001) + (500 * 0.0000025) }
  let(:quiet_sink) { Class.new { %i[start delta reset finish fail].each { define_method(_1) { |*| nil } } } }
  # A response memo; with `dies` set, the process "dies" (a non-StandardError)
  # once it has kept a whole call.
  let(:memo) do
    Class.new do
      attr_reader :records
      attr_accessor :dies

      def initialize = @records = {}
      def fetch(key) = @records[key]

      def store(key, record)
        @records[key] = record
        raise(dies.tap { self.dies = nil }) if dies && record["complete"]
      end
    end.new
  end
  let(:killed) { Class.new(Exception) } # rubocop:disable Lint/InheritException

  around do |example|
    saved = [Smith.config.interrupting_errors, Smith.config.stream_sinks, Smith.config.response_memo]
    example.run
  ensure
    Smith.config.interrupting_errors, Smith.config.stream_sinks, Smith.config.response_memo = saved
    Smith::Testing.reset!
  end

  before { Smith.config.pricing = Smith.config.pricing.merge(%w[anthropic claude-sonnet-5-5] => rates) }

  # RubyLLM touchpoint: a context whose requests give up after `seconds`.
  def timing_out(seconds) = RubyLLM.context { |config| config.request_timeout = seconds }

  # RubyLLM touchpoint: what RubyLLM raises for a billing refusal.
  def payment_required = RubyLLM::PaymentRequiredError

  # RubyLLM touchpoint: each message a run restored from a budget pause
  # hands its chat, as its model and its tool calls' ids.
  def restored(continuation)
    Smith::Budget::Continuation.load(continuation).map { [_1.model_id, _1.tool_calls&.values&.map(&:id)] }
  end

  # An agent on the stand-in server, with its own output cap when `cap`;
  # its model looked up in RubyLLM's list when `listed`.
  def pinned(name, model: "claude-sonnet-5-5", provider: :anthropic, cap: nil, listed: false, &body)
    Smith::Agent::Registry.delete(:spec_ledger_agent)
    klass = with_stubbed_class(name, agent_class) do
      register_as :spec_ledger_agent
      model model, provider:, assume_model_exists: !listed
      params max_tokens: cap if cap
    end
    klass.class_exec(&body) if body
    klass
  end

  def held_run(name, **step)
    held = ledger
    asking(name, **step) { |_scope| held }.new(context: {}).run!
  end

  def streamed_to_sink
    sink = quiet_sink.new
    Smith.config.stream_sinks = { reply: ->(_info) { sink } }
  end

  def body(request = server.requests.sole) = request.body

  # The memo's kept replies, each as the model it names.
  def kept_models = memo.records.values.flat_map { _1["messages"] }.filter_map { _1["model_id"] }

  def streamed(texts, stop:, input:, output:)
    deltas = texts.map { { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: _1 } } }
    [{ type: "message_start", message: { id: "msg_s", model: "claude-sonnet-5-5",
                                         usage: { input_tokens: input, output_tokens: 1 } } },
     { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }, *deltas,
     { type: "content_block_stop", index: 0 },
     { type: "message_delta", delta: stop ? { stop_reason: stop } : {}, usage: { output_tokens: output } },
     { type: "message_stop" }]
  end

  describe "usage" do
    it "records what a response reported: uncached input, output, cache reads and writes, and thinking" do
      pinned("SpecPinUsageAgent", cap: 500)
      server.reply(json: message("Fit.").merge("usage" => usage))
      result = asking("SpecPinUsageWorkflow").new(context: {}).run!
      entry = result.usage_entries.sole

      expect(result.state).to eq(:done)
      expect(entry.to_h.slice(:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens,
                              :thinking_tokens, :stop_reason, :provider_message_id))
        .to eq(input_tokens: 100, output_tokens: 20, cache_read_tokens: 4_000, cache_write_tokens: 500,
               thinking_tokens: 12, stop_reason: "end_turn", provider_message_id: "msg_1")
      expect(entry.cost).to be_within(1e-12).of(spent)
      expect([result.total_tokens, result.total_cost]).to match([4_620, be_within(1e-12).of(spent)])
    end

    it "settles a held request on the host's ledger at what it spent, not at its hold" do
      pinned("SpecPinSettledAgent", cap: 500)
      server.reply(json: message("Fit.").merge("usage" => usage))
      held_run("SpecPinSettledWorkflow")
      (reserve, key, hold), (settle, settled_key, settled) = ledger.calls

      expect([reserve, settle, settled_key]).to eq([:reserve, :reconcile, key])
      expect([settled.input_tokens, settled.output_tokens]).to eq([4_600, 20])
      expect(settled.cost).to be_within(1e-12).of(spent)
      expect(settled).not_to eq(hold)
    end
  end

  describe "the output cap" do
    it "holds the cap the request sends, the agent's own" do
      pinned("SpecPinCappedAgent", cap: 300)
      server.reply(json: message("Fit."))
      held_run("SpecPinCappedWorkflow")

      expect([ledger.calls.first[2].output_tokens, body["max_tokens"]]).to eq([300, 300])
    end

    # 1.16 does not list claude-sonnet-5-5 and sends 4,096; 2.2.3 lists it at
    # 128,000. Holding and sending that instead holds 31 times more for every
    # uncapped request: a decision for slice 3 or 4 to state, so this fails
    # until it is made, whichever way.
    it "holds and sends 4,096 output tokens when the agent sets no cap" do
      pinned("SpecPinUncappedAgent")
      server.reply(json: message("Fit."))
      held_run("SpecPinUncappedWorkflow")

      expect([ledger.calls.first[2].output_tokens, body["max_tokens"]]).to eq([4_096, 4_096])
    end

    it "sends a cut-off reply's retry with the larger cap" do
      pinned("SpecPinRetriedAgent", cap: 300) { on_truncation retry_with: { max_tokens: 8_000 } }
      server.reply(json: message("Hal", stop: "max_tokens")).reply(json: message("Whole."))
      result = asking("SpecPinRetriedWorkflow").new(context: {}).run!

      expect([result.state, result.context[:answer]]).to eq([:done, "Whole."])
      expect(server.requests.map { body(_1)["max_tokens"] }).to eq([300, 8_000])
    end

    it "names an OpenAI reasoning model's cap as that model takes it" do
      # RubyLLM touchpoint: its list names gpt-5 a model that reasons.
      pinned("SpecPinReasoningAgent", model: "gpt-5", provider: :openai, cap: 300)
      server.reply(json: { "id" => "chatcmpl-1", "object" => "chat.completion", "model" => "gpt-5",
                           "choices" => [{ "index" => 0, "message" => { "role" => "assistant", "content" => "Fit." },
                                           "finish_reason" => "stop" }],
                           "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2 } })
      result = asking("SpecPinReasoningWorkflow").new(context: {}).run!

      expect([result.state, server.requests.sole.path]).to eq([:done, "/v1/chat/completions"])
      expect(body.slice("max_tokens", "max_completion_tokens")).to eq("max_completion_tokens" => 300)
    end
  end

  describe "the prompt cache" do
    it "asks Anthropic for the automatic cache in the request, and holds the request as a cache write" do
      pinned("SpecPinCacheAgent", cap: 300) { prompt_cache :automatic }
      server.reply(json: message("Fit."))
      held_run("SpecPinCacheWorkflow")
      hold = ledger.calls.first[2]

      expect(body["cache_control"]).to eq("type" => "ephemeral")
      expect(hold.cost).to be_within(1e-12).of((hold.input_tokens * 0.0000025) + (300 * 0.00001))
    end
  end

  describe "a request that may have been billed" do
    let(:painted) do
      { "created" => 1, "data" => [{ "b64_json" => ["\x89PNG\r\n\x1A\n".b].pack("m0") }],
        "usage" => { "input_tokens" => 40, "output_tokens" => 823 } }
    end

    it "never sends again an image request whose answer timed out, to its model or a fallback, and charges its hold" do
      slow = timing_out(0.3)
      Smith.config.pricing = Smith.config.pricing.merge(
        %w[openai gpt-image-test] => rates.merge(image_output_tokens: { "1024x1024" => { "low" => 823 } })
      )
      pinned("SpecPinPaintAgent", model: "gpt-image-test", provider: :openai) do
        image size: "1024x1024", quality: "low"
        context slow # RubyLLM touchpoint: the agent macro taking a RubyLLM context
        fallback_models "openai/gpt-image-other"
      end
      server.reply(json: painted, after: 1.5).reply(json: painted)
      error = held_run("SpecPinPaintWorkflow").last_error
      (_, _, hold), (settle, _, charged) = ledger.calls

      expect(error).to be_a(Smith::RequestOutcomeUncertain)
      expect(error.message).to end_with("it may have been billed")
      expect(Smith::Errors.retry_forbidden?(error)).to be(true)
      expect([hold.output_tokens, hold.cost]).to match([823, be_within(1e-12).of((hold.input_tokens * 0.000002) +
                                                                                   (823 * 0.00001))])
      expect([settle, charged]).to eq([:reconcile, hold])
      expect(server.requests.length).to eq(1)
    end
  end

  describe "a text request whose connection fails" do
    it "goes to the fallback model when the connection drops once the request is sent" do
      pinned("SpecPinDropAgent", cap: 300) { fallback_models model: "claude-haiku-5-5", provider: :anthropic }
      server.reply(drop: true).reply(json: message("Open at 8.", id: "msg_h"))
      result = asking("SpecPinDropWorkflow").new(context: {}).run!

      expect([result.state, result.context[:answer]]).to eq([:done, "Open at 8."])
      expect(server.requests.map { body(_1)["model"] }).to eq(%w[claude-sonnet-5-5 claude-haiku-5-5])
    end

    it "leaves the step its retries when the connection drops and no fallback is left" do
      pinned("SpecPinDropOnlyAgent", cap: 300)
      server.reply(drop: true)
      result = asking("SpecPinDropOnlyWorkflow").new(context: {}).run!

      expect([result.state, result.last_error.class, server.requests.length]).to eq([:failed, Smith::AgentError, 1])
    end

    it "leaves the step its retries when its answer times out" do
      slow = timing_out(0.3)
      pinned("SpecPinSlowAgent", cap: 300) { context slow }
      server.reply(json: message("Late."), after: 1.5)
      result = asking("SpecPinSlowWorkflow").new(context: {}).run!

      expect([result.state, result.last_error.class, server.requests.length]).to eq([:failed, Smith::AgentError, 1])
    end
  end

  # Anthropic's monthly spend cap, which comes as a rate limit: Smith takes it
  # as a billing refusal (Smith::BillingRefusals), which neither RubyLLM 1.16
  # nor 2.2.3 does on its own (2.2.3 maps only a "credit balance is too low").
  describe "a refusal past a spending limit" do
    let(:spend_cap) do
      { type: "error", error: { type: "rate_limit_error",
                                message: "You have reached your API usage limits: your organization has crossed " \
                                         "its monthly API usage threshold.",
                                details: { error_code: "enforced_spend_limit_reached" } } }
    end

    it "arrives as RubyLLM's payment-required error, though it comes as a rate limit, so a host can wait for credit" do
      pinned("SpecPinCreditAgent", cap: 300)
      server.reply(json: spend_cap, status: "429 Too Many Requests")
      failed = asking("SpecPinCreditWorkflow").new(context: {}).run!
      Smith.config.interrupting_errors = [payment_required]
      server.reply(json: spend_cap, status: "429 Too Many Requests")
      waiting = asking("SpecPinCreditWaitWorkflow").new(context: {})

      expect([failed.state, failed.last_error.cause.class]).to eq([:failed, payment_required])
      expect(failed.last_error.cause.message).to start_with("You have reached your API usage limits")
      expect { waiting.run! }.to raise_error(payment_required)
      expect(waiting.state).to eq(:idle)
    end
  end

  describe "Smith::Testing" do
    it "answers a stubbed agent's calls, plain and streamed, as its model, with no request to the provider" do
      agent = pinned("SpecPinStubbedAgent", cap: 300)
      Smith::Testing.stub_agent(agent, outputs: "Stubbed.", usage: { input_tokens: 40, output_tokens: 8 })
      Smith.config.response_memo = memo
      plain = asking("SpecPinStubbedWorkflow").new(context: {}).run!
      streamed_to_sink
      streamed = asking("SpecPinStubbedStreamWorkflow", stream: :reply).new(context: {}).run!

      expect([plain, streamed].map { [_1.state, _1.context[:answer]] }).to eq([[:done, "Stubbed."]] * 2)
      expect(kept_models).to eq(%w[claude-sonnet-5-5] * 2)
      expect(server.requests).to be_empty
    end
  end

  describe "a response memo" do
    # The run, killed right after the memo keeps its call whole, restored
    # and run on.
    def replayed(name, cache_read, cache_write)
      pinned("#{name}Agent", cap: 300)
      (Smith.config.response_memo = memo).dies = killed
      usage = { "input_tokens" => 40, "output_tokens" => 9, "cache_read_input_tokens" => cache_read,
                "cache_creation_input_tokens" => cache_write }
      server.reply(json: message("Kept answer.").merge("usage" => usage))
      run_and_restore(asking("#{name}Workflow"), "run-#{name}")
    end

    def run_and_restore(klass, key)
      adapter = Smith::PersistenceAdapters::Memory.new
      expect { klass.new(context: {}).run_persisted!(key, adapter:) }.to raise_error(killed)
      klass.restore(key, adapter:).run_persisted!(key, adapter:)
    end

    def counts(result)
      result.usage_entries.map { _1.to_h.slice(:input_tokens, :cache_read_tokens, :cache_write_tokens) }
    end

    it "replays a kept reply that read and wrote the cache, sending nothing again, its counts kept" do
      done = replayed("SpecPinMemoCache", 300, 1_200)

      expect([done.state, done.context[:answer], server.requests.length]).to eq([:done, "Kept answer.", 1])
      expect(counts(done)).to eq([{ input_tokens: 40, cache_read_tokens: 300, cache_write_tokens: 1_200 }])
    end

    it "replays a kept reply whose cache counts are zero, as Anthropic reports them unused" do
      done = replayed("SpecPinMemoZero", 0, 0)

      expect([done.state, done.context[:answer], server.requests.length]).to eq([:done, "Kept answer.", 1])
      expect(counts(done)).to eq([{ input_tokens: 40, cache_read_tokens: 0, cache_write_tokens: 0 }])
    end
  end

  describe "a model named by an alias RubyLLM's list also knows" do
    it "is sent, recorded and priced under the id the agent names" do
      # RubyLLM touchpoint: its list resolves claude-sonnet-4-5 to a dated id.
      Smith.config.pricing = Smith.config.pricing.merge(%w[anthropic claude-sonnet-4-5] => rates)
      pinned("SpecPinAliasAgent", model: "claude-sonnet-4-5", cap: 300)
      server.reply(json: message("Fit.").merge("model" => "claude-sonnet-4-5-20250929"))
      entry = held_run("SpecPinAliasWorkflow").usage_entries.sole

      expect([body["model"], entry.model]).to eq(%w[claude-sonnet-4-5 claude-sonnet-4-5])
      expect(entry.cost).to be_within(1e-12).of((100 * 0.000002) + (20 * 0.00001))
      expect(ledger.calls.first[2].cost).to be_a(Float)
    end
  end

  describe "a batch step" do
    it "hands its request to the host's queue, sends nothing, and takes the delivered result as its reply" do
      pinned("SpecPinBatchAgent", cap: 300)
      queue = Smith.config.batch_queue = batch_queue
      klass = asking("SpecPinBatchWorkflow", mode: :batch)
      adapter = Smith::PersistenceAdapters::Memory.new
      klass.new(context: {}).run_persisted!("run-pin-batch", adapter:)
      request = queue.items.sole
      token = klass.restore("run-pin-batch", adapter:).awaiting.token
      delivered = { request[:custom_id] => { "type" => "succeeded", "message" => message("Batched.", id: "msg_b") } }
      klass.resume!("run-pin-batch", event: :batch_result, token:, payload: delivered, adapter:)
      done = klass.restore("run-pin-batch", adapter:)

      expect(request[:request]["params"]).to include("max_tokens" => 300, "stream" => false)
      expect([done.state, done.to_state[:context][:answer]]).to eq([:done, "Batched."])
      expect(server.requests).to be_empty
    end
  end

  describe "a run restored from a budget pause" do
    let(:thought) { { "type" => "thinking", "thinking" => "Look the clinic up.", "signature" => "sig-1" } }
    let(:call) do
      { "type" => "tool_use", "id" => "toolu_1", "name" => "spec_pin_lookup", "input" => { "query" => "clinic" } }
    end

    before do
      stub_const("SpecPinLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| { found: "#{query} is open 8 to 6" } }
      end)
    end

    # Admits the first request, refuses the second, then admits once topped up.
    def topping_ledger
      state = { reserves: 0, topped: false }
      [ledger_class.new(admit: ->(_amount) { (state[:reserves] += 1) != 2 || state[:topped] }), state]
    end

    def pausing(name, ledger)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        budget_ledger { |_scope| ledger }
        seed_messages { |_context| [{ role: :user, content: "find the hours" }] }
        transition :ask, from: :idle, to: :done do
          execute :spec_ledger_agent, output_to: :answer
          retry_on Smith::BudgetUnavailable, attempts: 3, backoff: 60, durable: true
          on_failure :fail
        end
      end
    end

    it "continues with each message's model, its thinking and its tool calls' provider ids" do
      # RubyLLM touchpoint: its list knows claude-sonnet-4-5 and its thinking budget.
      pinned("SpecPinPauseAgent", model: "claude-sonnet-4-5", cap: 2_000, listed: true) do
        tools SpecPinLookup
        thinking budget: 1_024
      end
      held, state = topping_ledger
      klass = pausing("SpecPinPauseWorkflow", held)
      asked = message(nil, id: "msg_a", content: [thought, call], stop: "tool_use")
      server.reply(json: asked.merge("model" => "claude-sonnet-4-5")).reply(json: message("Open 8 to 6.", id: "msg_b"))
      adapter = Smith::PersistenceAdapters::Memory.new
      klass.new(context: {}).run_persisted!("run-pin-pause", adapter:)
      continuation = JSON.parse(adapter.fetch("run-pin-pause")).dig("pending_retry", "continuation")
      state[:topped] = true
      waiting = klass.restore("run-pin-pause", adapter:).awaiting
      klass.expire_wait!("run-pin-pause", token: waiting.token, now: Time.now.utc + 3_600, adapter:)
      done = klass.restore("run-pin-pause", adapter:).run_persisted!("run-pin-pause", adapter:)
      _user, assistant, result = body(server.requests.last)["messages"]

      expect(restored(continuation)).to eq([["claude-sonnet-4-5", ["toolu_1"]], [nil, nil]])
      expect([done.state, done.context[:answer], server.requests.length]).to eq([:done, "Open 8 to 6.", 2])
      expect(assistant).to eq("role" => "assistant", "content" => [thought, call])
      expect(result["content"].map { _1["tool_use_id"] }).to eq(["toolu_1"])
    end
  end

  describe "a streamed reply that hits its cap" do
    it "reads as limit reached when it ends at its cap without a stop reason, its usage recorded" do
      pinned("SpecPinStreamCapAgent", cap: 50)
      streamed_to_sink
      server.reply(events: streamed(%w[Hal f], stop: nil, input: 30, output: 50))
      result = asking("SpecPinStreamCapWorkflow", stream: :reply).new(context: {}).run!

      expect([result.last_error.class, result.last_error.stop_reason])
        .to eq([Smith::OutputTruncated, "output_limit_reached"])
      expect(result.usage_entries.map { _1.to_h.slice(:input_tokens, :output_tokens, :stop_reason, :mode) })
        .to eq([{ input_tokens: 30, output_tokens: 50, stop_reason: "output_limit_reached", mode: :stream }])
    end

    it "reads as the provider's own stop reason when it says, its usage recorded" do
      pinned("SpecPinStreamStopAgent", cap: 50)
      streamed_to_sink
      server.reply(events: streamed(%w[Hal f], stop: "max_tokens", input: 30, output: 50))
      result = asking("SpecPinStreamStopWorkflow", stream: :reply).new(context: {}).run!

      expect([result.last_error.class, result.last_error.stop_reason]).to eq([Smith::OutputTruncated, "max_tokens"])
      expect(result.usage_entries.map { _1.to_h.slice(:input_tokens, :output_tokens, :stop_reason, :mode) })
        .to eq([{ input_tokens: 30, output_tokens: 50, stop_reason: "max_tokens", mode: :stream }])
    end
  end

  # Anthropic's own stop reason, kept as it says it: RubyLLM 2.x's finish
  # reasons merge a refusal into content_filter and a full context window into
  # max_tokens (review 3.3), where Smith acts on the difference.
  describe "a streamed reply's own stop reason" do
    it "keeps a refusal as refusal" do
      pinned("SpecPinStreamRefusalAgent", cap: 50)
      streamed_to_sink
      server.reply(events: streamed(%w[No], stop: "refusal", input: 30, output: 2))
      result = asking("SpecPinStreamRefusalWorkflow", stream: :reply).new(context: {}).run!

      expect([result.last_error.class, result.last_error.stop_reason]).to eq([Smith::OutputRefused, "refusal"])
    end

    it "never retries a reply a full context window cut off with a larger cap" do
      pinned("SpecPinStreamWindowAgent", cap: 50) { on_truncation retry_with: { max_tokens: 8_000 } }
      streamed_to_sink
      server.reply(events: streamed(%w[Hal], stop: "model_context_window_exceeded", input: 30, output: 20))
      result = asking("SpecPinStreamWindowWorkflow", stream: :reply).new(context: {}).run!

      expect([result.last_error.class, result.last_error.stop_reason, server.requests.length])
        .to eq([Smith::OutputTruncated, "model_context_window_exceeded", 1])
    end
  end

  # RubyLLM touchpoint: its list gives claude-sonnet-4-5 64,000 output tokens,
  # which a request with no cap sends and Smith reads as its limit.
  describe "a request with no cap, on a model RubyLLM lists" do
    before do
      Smith.config.pricing = Smith.config.pricing.merge(%w[anthropic claude-sonnet-4-5] => rates,
                                                        %w[anthropic claude-sonnet-4-5-20250929] => rates)
    end

    def listed(name, &) = pinned(name, model: "claude-sonnet-4-5", listed: true, &)

    it "reads a streamed reply that ends at the model's limit without a stop reason as limit reached" do
      listed("SpecPinListedLimitAgent")
      streamed_to_sink
      server.reply(events: streamed(%w[Hal f], stop: nil, input: 30, output: 64_000))
      result = asking("SpecPinListedLimitWorkflow", stream: :reply).new(context: {}).run!

      expect([body["max_tokens"], result.last_error.stop_reason]).to eq([64_000, "output_limit_reached"])
    end

    it "reads one that ends short of it, though past 4,096, as incomplete" do
      listed("SpecPinListedShortAgent")
      streamed_to_sink
      server.reply(events: streamed(%w[Hal f], stop: nil, input: 30, output: 5_000))
      result = asking("SpecPinListedShortWorkflow", stream: :reply).new(context: {}).run!

      expect(result.last_error.stop_reason).to eq("stream_incomplete")
    end

    it "never retries a cut-off reply with a cap smaller than the one it was sent with" do
      listed("SpecPinListedRetryAgent") { on_truncation retry_with: { max_tokens: 8_000 } }
      server.reply(json: message("Hal", stop: "max_tokens")).reply(json: message("Whole."))
      result = asking("SpecPinListedRetryWorkflow").new(context: {}).run!

      expect([result.last_error.class, server.requests.map { body(_1)["max_tokens"] }])
        .to eq([Smith::OutputTruncated, [64_000]])
    end
  end
end
