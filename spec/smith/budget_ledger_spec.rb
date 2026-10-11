# frozen_string_literal: true

require "logger"
require "stringio"

# A host's budget ledger (`budget_ledger`): each provider request a step makes
# is held on it before it is sent, then settled with what it spent.
RSpec.describe "Smith budget ledgers" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:server) { SseServer.new }
  let(:log) { StringIO.new }
  let(:ledger_class) do
    Class.new do
      attr_reader :calls

      def initialize(admit: true)
        @calls = []
        @admit = admit
      end

      def reserve!(amount, key:, expires_at:)
        @calls << [:reserve, key, amount, expires_at]
        @admit.respond_to?(:call) ? @admit.call(amount) : @admit
      end

      def reconcile!(key, amount) = @calls << [:reconcile, key, amount]
      def release!(key) = @calls << [:release, key]
      def kinds = @calls.map(&:first)
      def keys = @calls.map { _1[1] }
    end
  end
  let(:ledger) { ledger_class.new }
  let(:prices) { { input_cost_per_token: 0.000003, output_cost_per_token: 0.000015, batch_discount: 0.5 } }

  around do |example|
    config = RubyLLM.config
    saved = %i[anthropic_api_key anthropic_api_base max_retries].to_h { [_1, config.public_send(_1)] }
    saved_smith = %i[pricing logger batch_queue budget_hold_ttl budget_hold_output_tokens]
                  .to_h { [_1, Smith.config.public_send(_1)] }
    example.run
  ensure
    server.close
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
    saved_smith.each { |key, value| Smith.config.public_send(:"#{key}=", value) }
  end

  before do
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test"
      config.anthropic_api_base = server.url
      config.max_retries = 0
    end
    Smith.config.pricing = { %w[anthropic claude-sonnet-5-5] => prices, %w[anthropic claude-haiku-5-5] => prices }
    Smith.config.logger = Logger.new(log)
    allow_any_instance_of(workflow_class).to receive(:sleep)
  end

  def message(text, id: "msg_1", tokens: [100, 20], content: nil, stop: "end_turn")
    { "id" => id, "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
      "content" => content || [{ "type" => "text", "text" => text }], "stop_reason" => stop,
      "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
  end

  def agent(name, register: :spec_ledger_agent, model: "claude-sonnet-5-5", &body)
    Smith::Agent::Registry.delete(register)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model model, provider: :anthropic, assume_model_exists: true
      params max_tokens: 500
    end
    klass.class_exec(&body) if body
    klass
  end

  def asking(name, agent: :spec_ledger_agent, mode: nil, **step, &ledger_block)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger(&ledger_block)
      seed_messages { |_context| [{ role: :user, content: "classify this posting" }] }
      transition :ask, from: :idle, to: :done do
        execute agent, output_to: :answer, **({ mode: } if mode).to_h, **step
        on_failure :fail
      end
    end
  end

  def traced
    traces = Smith::Trace::Memory.new
    allow(Smith.config).to receive(:trace_adapter).and_return(traces)
    traces
  end

  def amount(input, output, cost) = Smith::Budget::Amount.new(input_tokens: input, output_tokens: output, cost:)

  it "holds each request on the run's ledger before sending it, and reconciles what it spent" do
    traces = traced
    agent("SpecLedgerAgent")
    server.reply(json: message("fit"))
    held = ledger
    workflow = asking("SpecLedgerWorkflow") { |_context| held }.new(context: {})
    before = Time.now.utc

    expect(workflow.run!.state).to eq(:done)
    reserve, reconcile = ledger.calls
    attempt_id = traces.traces.find { _1[:type] == :provider_call }[:data][:attempt_id]
    expect(ledger.keys).to eq(["#{attempt_id}:1"] * 2)
    hold = reserve[2]
    expect([hold.output_tokens, hold.input_tokens.positive?]).to eq([500, true])
    expect(hold.cost).to be_within(1e-12).of((hold.input_tokens * 0.000003) + (500 * 0.000015))
    expect(reserve[3]).to be_between(before + 3600, Time.now.utc + 3600)
    expect(reconcile).to eq([:reconcile, "#{attempt_id}:1", amount(100, 20, (100 * 0.000003) + (20 * 0.000015))])
  end

  it "holds a streamed request, and reconciles the usage its stream reported" do
    agent("SpecLedgerStreamAgent")
    sink = Class.new { %i[start delta reset finish fail].each { |name| define_method(name) { |*| nil } } }
    allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new })
    server.reply(events: [
                   { type: "message_start",
                     message: { id: "msg_s", model: "m", usage: { input_tokens: 30, output_tokens: 0 } } },
                   { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
                   { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "streamed" } },
                   { type: "content_block_stop", index: 0 },
                   { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 7 } },
                   { type: "message_stop" }
                 ])
    held = ledger

    expect(asking("SpecLedgerStreamWorkflow", stream: :reply) { |_context| held }.new(context: {}).run!.state)
      .to eq(:done)
    expect(ledger.calls.last).to eq([:reconcile, ledger.keys.first, amount(30, 7, (30 * 0.000003) + (7 * 0.000015))])
  end

  it "reconciles a request's cache reads and writes as input, and holds each fan-out branch in its own thread" do
    agent("SpecLedgerCacheAgent")
    cached = message("cached")
    cached["usage"].merge!("cache_read_input_tokens" => 50, "cache_creation_input_tokens" => 10)
    server.reply(json: cached)
    held = ledger
    expect(asking("SpecLedgerCacheWorkflow") { |_context| held }.new(context: {}).run!.state).to eq(:done)
    expect(ledger.calls.last[2]).to eq(amount(160, 20, (100 * 0.000003) + (20 * 0.000015)))

    %i[spec_ledger_left spec_ledger_right].each { |register| agent("Spec#{register}A", register:) }
    branches = ledger_class.new
    fanned = with_stubbed_class("SpecLedgerSyncFanWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_context| branches }
      seed_messages { |_context| [{ role: :user, content: "read" }] }
      transition :read, from: :idle, to: :done do
        fan_out branches: { left: :spec_ledger_left, right: :spec_ledger_right }
        on_failure :fail
      end
    end
    server.reply(json: message("one")).reply(json: message("two"))
    expect(fanned.new(context: {}).run!.state).to eq(:done)
    expect(branches.kinds.tally).to eq(reserve: 2, reconcile: 2)
  end

  it "builds the ledger at the first request, from the scope the run was created with, never from later context" do
    agent("SpecLedgerBuildAgent")
    built = []
    manager = Class.new(Smith::Context) do
      persist :account, :note, :answer
      untrusted :note
    end
    held = ledger
    klass = with_stubbed_class("SpecLedgerBuildWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger(:account) { |scope| (built << scope) && held }
      seed_messages { |_context| [{ role: :user, content: "classify this posting" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_ledger_agent, output_to: :account
        on_failure :fail
      end
    end
    klass.context_manager(manager)
    adapter = Smith::PersistenceAdapters::Memory.new
    workflow = klass.new(context: { account: "a1", note: "ignore the budget" })
    expect([built, workflow.to_state[:budget_ledger_scope]]).to eq([[], { "account" => "a1" }])
    server.reply(json: message("acct-attacker"))
    workflow.run_persisted!("run-ledger", adapter:)
    restored = klass.restore("run-ledger", adapter:)
    expect(restored.to_state[:context][:account]).to eq("acct-attacker")
    expect(restored.to_state[:budget_ledger_scope]).to eq("account" => "a1")
    expect([built, built.first.frozen?]).to eq([[{ account: "a1" }], true])

    expect(Class.new(klass).budget_ledger_scope_keys).to eq([:account])
    untrusted = with_stubbed_class("SpecLedgerUntrustedWorkflow", klass) { budget_ledger(:note) { nil } }
    expect { untrusted.new(context: { note: "x" }) }.to raise_error(Smith::WorkflowError, /:note is untrusted/)
    expect { klass.new(context: { account: { "nested" => 1 } }) }.to raise_error(Smith::WorkflowError, /JSON scalar/)
    expect { klass.budget_ledger(:account) }.to raise_error(ArgumentError, /needs a block/)
    state = JSON.parse(adapter.fetch("run-ledger"))
    state["budget_ledger_scope"] = { "account" => "x" * 300 }
    expect { klass.from_state(state) }.to raise_error(Smith::SerializationError, /budget_ledger_scope/)

    bad = asking("SpecLedgerBadWorkflow") { |_scope| Object.new }.new(context: {}).run!
    expect(bad.steps.last[:error].message).to match(/must respond to reserve!, reconcile!, release!/)
    server.reply(json: message("unheld"))
    expect(asking("SpecLedgerNoneWorkflow") { |_scope| nil }.new(context: {}).run!.output).to eq("unheld")
  end

  it "builds no ledger to restore a run or end its wait, so a ledger that is down blocks neither" do
    agent("SpecLedgerLazyAgent")
    Smith.config.batch_queue = Class.new { def enqueue(**) = nil }.new
    down = false
    held = ledger
    klass = asking("SpecLedgerLazyWorkflow", mode: :batch) do |_scope|
      raise IOError, "ledger service down" if down

      held
    end
    adapter = Smith::PersistenceAdapters::Memory.new
    klass.new(context: {}).run_persisted!("run-lazy", adapter:)
    down = true
    waiting = klass.restore("run-lazy", adapter:).awaiting
    expect(klass.expire_wait!("run-lazy", token: waiting.token, now: Time.parse(waiting.deadline_at.to_s) + 1,
                                          adapter:)).to eq(:expired)
    stored = JSON.parse(adapter.fetch("run-lazy"))
    expect([stored["state"], stored.dig("last_failed_step", "error_class")]).to eq(%w[failed Smith::BatchResultFailed])
    expect(log.string).to include("Smith budget ledger settle error: the budget ledger could not be built (IOError)")
  end

  it "refuses a request its ledger will not admit, before anything is sent" do
    agent("SpecLedgerRefusedAgent")
    refusing = ledger_class.new(admit: false)
    result = asking("SpecLedgerRefusedWorkflow") { |_context| refusing }.new(context: {}).run!

    expect([result.state, server.requests]).to eq([:failed, []])
    expect(result.steps.last[:error]).to be_a(Smith::BudgetUnavailable)
    expect(Smith::BudgetUnavailable.new).to be_a(Smith::BudgetExceeded)
    expect(refusing.kinds).to eq([:reserve])

    adapter = Smith::PersistenceAdapters::Memory.new
    stored = asking("SpecLedgerStoredWorkflow") { |_context| refusing }
    stored.new(context: {}).run_persisted!("run-refused", adapter:)
    state = JSON.parse(adapter.fetch("run-refused"))
    expect(state.dig("last_failed_step", "error_family")).to eq("budget_exceeded")
    state["last_failed_step"]["error_family"] = "agent_error"
    expect { stored.from_state(state) }.to raise_error(Smith::PersistedFailureInvalid, /class and family disagree/)

    expect(stored.restore("run-refused", adapter:).send(:reconstruct_failed_step)[:error])
      .to be_a(Smith::BudgetUnavailable)
    loose = ledger_class.new(admit: ->(_amount) { "ok" })
    expect(asking("SpecLedgerLooseWorkflow") { |_scope| loose }.new(context: {}).run!.steps.last[:error])
      .to be_a(Smith::BudgetUnavailable)

    traces = traced
    agent("SpecLedgerDownAgent") { fallback_models model: "claude-haiku-5-5", provider: :anthropic }
    raising = ledger_class.new(admit: ->(_amount) { raise Faraday::ConnectionFailed, "ledger host unreachable" })
    failed = asking("SpecLedgerDownWorkflow") { |_scope| raising }.new(context: {}).run!
    expect(failed.steps.last[:error]).to be_a(Smith::BudgetLedgerError)
    expect(failed.steps.last[:error].message).to eq("the budget ledger could not reserve (Faraday::ConnectionFailed)")
    expect([raising.kinds, server.requests]).to eq([%i[reserve release], []])
    expect(traces.traces.select { _1[:type] == :provider_call }.length).to eq(1)
  end

  it "holds a call's first request, reconciles every round of its tool loop, and releases one that failed early" do
    stub_const("SpecLedgerLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      def perform(query:) = { found: query }
    end)
    agent("SpecLedgerLoopAgent") do
      tools SpecLedgerLookup
      fallback_models model: "claude-haiku-5-5", provider: :anthropic
    end
    tool_use = [{ "type" => "tool_use", "id" => "toolu_1", "name" => "spec_ledger_lookup",
                  "input" => { "query" => "x" } }]
    down = { type: "error", error: { type: "api_error", message: "down" } }
    server.reply(json: down, status: "500 Internal Server Error")
          .reply(json: message(nil, id: "msg_a", content: tool_use, stop: "tool_use", tokens: [10, 4]))
          .reply(json: message("done", id: "msg_b", tokens: [12, 3]))
    held = ledger

    expect(asking("SpecLedgerLoopWorkflow") { |_context| held }.new(context: {}).run!.output).to eq("done")
    expect(ledger.kinds).to eq(%i[reserve release reserve reconcile reconcile])
    failed, first, second = ledger.keys.values_at(0, 2, 4)
    expect([first, second].map { _1.split(":").last }).to eq(%w[1 2])
    expect([first, second].map { _1.split(":").first }.uniq.length).to eq(1)
    expect(failed.split(":").first).not_to eq(first.split(":").first)
    expect(ledger.calls[3][2]).to eq(amount(10, 4, (10 * 0.000003) + (4 * 0.000015)))
    expect(ledger.calls[4][2]).to eq(amount(12, 3, (12 * 0.000003) + (3 * 0.000015)))
  end

  it "holds no RubyLLM call of a tool's own, made while the step's request is held" do
    stub_const("SpecLedgerAsker", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      def perform(query:)
        RubyLLM.chat(model: "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true).ask(query).content
      end
    end)
    agent("SpecLedgerAskerAgent") { tools SpecLedgerAsker }
    tool_use = [{ "type" => "tool_use", "id" => "toolu_1", "name" => "spec_ledger_asker",
                  "input" => { "query" => "x" } }]
    server.reply(json: message(nil, id: "msg_a", content: tool_use, stop: "tool_use", tokens: [10, 4]))
          .reply(json: message("inner", id: "msg_inner", tokens: [3, 1]))
          .reply(json: message("done", id: "msg_b", tokens: [12, 3]))
    held = ledger

    expect(asking("SpecLedgerAskerWorkflow") { |_context| held }.new(context: {}).run!.output).to eq("done")
    expect([server.requests.length, ledger.kinds]).to eq([3, %i[reserve reconcile reconcile]])
  end

  it "keeps the answer when the ledger cannot record what it spent, and logs the error by class" do
    agent("SpecLedgerSettleAgent")
    server.reply(json: message("kept"))
    failing = ledger_class.new
    failing.define_singleton_method(:reconcile!) { |_key, _amount| raise IOError, "ledger down" }

    expect(asking("SpecLedgerSettleWorkflow") { |_context| failing }.new(context: {}).run!.output).to eq("kept")
    expect(log.string).to include("Smith budget ledger reconcile! error: IOError")
    expect(log.string).not_to include("ledger down")
  end

  it "charges a nested workflow's requests to the enclosing run's ledger when it has none of its own" do
    agent("SpecLedgerNestedAgent")
    server.reply(json: message("nested"))
    child = asking("SpecLedgerChildWorkflow")
    child.instance_variable_set(:@budget_ledger_builder, nil)
    held = ledger
    parent = with_stubbed_class("SpecLedgerParentWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_context| held }
      transition(:nest, from: :idle, to: :done) do
        workflow child
        on_failure :fail
      end
    end

    expect(parent.new(context: {}).run!.state).to eq(:done)
    expect(ledger.kinds).to eq(%i[reserve reconcile])
  end

  describe "a batch step" do
    let(:queue) do
      Class.new do
        attr_reader :items

        def initialize = @items = []
        def enqueue(**request) = @items << request
      end.new
    end

    before { Smith.config.batch_queue = queue }

    def deliver(workflow, results)
      workflow.resume!(event: :batch_result, token: workflow.awaiting.token, payload: results)
    end

    it "holds each request at capture under its custom_id, at the batch discount, until its result settles it" do
      %i[spec_ledger_detect spec_ledger_extract].each do |register|
        agent("Spec#{register.to_s.split("_").last.capitalize}A", register:)
      end
      held = ledger
      klass = with_stubbed_class("SpecLedgerFanWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget_ledger { |_context| held }
        seed_messages { |_context| [{ role: :user, content: "read" }] }
        transition :read, from: :idle, to: :done do
          fan_out branches: { detect: :spec_ledger_detect, extract: :spec_ledger_extract }, mode: :batch
          on_failure :fail
        end
      end
      Smith.config.budget_hold_ttl = 60
      before = Time.now.utc
      workflow = klass.new(context: {})
      workflow.run!
      ids = queue.items.map { _1[:custom_id] }

      expect(ledger.calls.map { _1.first(2) }).to eq(ids.map { [:reserve, _1] })
      hold = ledger.calls.first[2]
      expect(hold.cost).to be_within(1e-12).of(((hold.input_tokens * 0.000003) + (500 * 0.000015)) * 0.5)
      expect(ledger.calls.first[3]).to be_between(before + (25 * 3600) + 60, Time.now.utc + (25 * 3600) + 60)

      errored = { "type" => "errored", "error" => { "type" => "error", "error" => { "type" => "api_error" } } }
      deliver(workflow, ids.first => errored, ids.last => { "type" => "succeeded", "message" => message("x") })
      expect(ledger.calls.drop(2)).to contain_exactly(
        [:release, ids.first], [:reconcile, ids.last, amount(100, 20, ((100 * 0.000003) + (20 * 0.000015)) * 0.5)]
      )
    end

    it "queues nothing past a refusal, releasing the holds taken, and releases every hold of an expired wait" do
      agent("SpecLedgerBatchAgent")
      refusing = ledger_class.new(admit: false)
      refused = asking("SpecLedgerBatchRefusedWorkflow", mode: :batch) { |_context| refusing }.new(context: {}).run!
      expect([refused.state, refused.steps.last[:error].class, queue.items])
        .to eq([:failed, Smith::BudgetUnavailable, []])

      %i[spec_ledger_first spec_ledger_second].each { |register| agent("Spec#{register}B", register:) }
      second = ledger_class.new(admit: ->(_amount) { (@admitted = (@admitted || 0) + 1) == 1 })
      half = with_stubbed_class("SpecLedgerHalfWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget_ledger { |_context| second }
        seed_messages { |_context| [{ role: :user, content: "read" }] }
        transition :read, from: :idle, to: :done do
          fan_out branches: { first: :spec_ledger_first, second: :spec_ledger_second }, mode: :batch
          on_failure :fail
        end
      end
      expect([half.new(context: {}).run!.state, queue.items]).to eq([:failed, []])
      expect(second.kinds).to eq(%i[reserve reserve release])
      expect(second.calls.last[1]).to eq(second.calls.first[1])

      # A retry's backoff starts with the holds the refused attempt took
      # already released.
      at_backoff = nil
      admitted = 0
      third = ledger_class.new(admit: ->(_amount) { (admitted += 1).odd? })
      allow_any_instance_of(workflow_class).to receive(:sleep) { at_backoff ||= third.kinds.dup }
      retrying = with_stubbed_class("SpecLedgerRetryHalfWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget_ledger { |_context| third }
        seed_messages { |_context| [{ role: :user, content: "read" }] }
        transition :read, from: :idle, to: :done do
          fan_out branches: { first: :spec_ledger_first, second: :spec_ledger_second }, mode: :batch
          retry_on Smith::BudgetUnavailable, attempts: 2, backoff: 1
          on_failure :fail
        end
      end
      expect(retrying.new(context: {}).run!.state).to eq(:failed)
      expect(at_backoff).to eq(%i[reserve reserve release])

      held = ledger
      klass = asking("SpecLedgerBatchExpiryWorkflow", mode: :batch) { |_context| held }
      adapter = Smith::PersistenceAdapters::Memory.new
      klass.new(context: {}).run_persisted!("run-expiry", adapter:)
      waiting = klass.restore("run-expiry", adapter:).awaiting
      klass.expire_wait!("run-expiry", token: waiting.token, now: Time.parse(waiting.deadline_at.to_s) + 1, adapter:)
      expect(ledger.calls.map(&:first)).to eq(%i[reserve release])
      expect(ledger.keys.uniq).to eq([queue.items.sole[:custom_id]])
    end

    it "releases holds taken when the step fails before queuing them" do
      agent("SpecLedgerShapeAgent")
      stamp = Class.new(Smith::Guardrails) do
        define_method(:stamp) { |context| context["stamped"] = true }
        input :stamp
      end
      held = ledger
      klass = with_stubbed_class("SpecLedgerShapeWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        guardrails stamp
        budget_ledger { |_context| held }
        transition :ask, from: :idle, to: :done do
          execute :spec_ledger_agent, mode: :batch
          on_failure :fail
        end
      end

      expect(klass.new(context: {}).run!.state).to eq(:failed)
      expect([ledger.kinds, queue.items]).to eq([%i[reserve release], []])
    end
  end

  it "warns in readiness when an agent's model has no price, as its holds carry no cost" do
    agent("SpecLedgerUnpricedAgent", model: "claude-unpriced-1")
    codes = asking("SpecLedgerUnpricedWorkflow") { |_context| nil }.runtime_readiness.runtime_diagnostics
                                                                   .map { [_1.severity, _1.code] }
    expect(codes).to eq([%i[warning budget_ledger_unpriced]])
    expect(asking("SpecLedgerPlainWorkflow").runtime_readiness.runtime_diagnostics).to eq([])
    expect { Smith.config.budget_hold_ttl = 0 }.to raise_error(ArgumentError)
  end

  it "estimates a hold from what the request carries, capped at the model's context window" do
    model = Struct.new(:id, :max_tokens, :context_window).new("claude-sonnet-5-5", 8_000, 1_000)
    image = RubyLLM::Attachment.new(StringIO.new("\x89PNG".b), filename: "a.png")
    messages = [RubyLLM::Message.new(role: :user, content: RubyLLM::Content.new("x" * 300, [image]))]
    tool = Struct.new(:name, :description, :params_schema).new("look", "y" * 6, { "type" => "object" })
    hold = Smith::Budget::RequestHold.for_request(provider: "anthropic", model:, messages:, tools: { look: tool },
                                                  schema: { "z" => 1 }, params: {})
    expect([hold.input_tokens, hold.output_tokens]).to eq([1_000, 8_000])

    small = model.to_h.merge(context_window: nil).then { Struct.new(*_1.keys).new(*_1.values) }
    text = [RubyLLM::Message.new(role: :user, content: "x" * 300)]
    estimate = Smith::Budget::RequestHold.for_request(provider: "anthropic", model: small, messages: text, tools: {},
                                                      schema: nil, params: { max_tokens: 50 })
    expect([estimate.input_tokens, estimate.output_tokens]).to eq([100 + 8, 50])
    counted = Smith::Budget::RequestHold.input_estimate(text, { look: tool }, { "z" => 1 })
    expect(counted).to eq(((300 + 4 + 6 + '{"type":"object"}'.bytesize + '{"z":1}'.bytesize + 2) / 3) + 8)
    expect(Smith::Budget::RequestHold.input_estimate(messages, {}, nil)).to eq(100 + 1_600 + 8)
    cap = Smith::Budget::RequestHold.method(:output_cap)
    expect(cap.call("gemini", { "generationConfig" => { "maxOutputTokens" => 7 } }, small)).to eq(7)
    expect(cap.call("gemini", { "generationConfig" => 7 }, small)).to eq(8_000)
    expect(cap.call("anthropic", { "generationConfig" => { "maxOutputTokens" => 7 } }, Object.new)).to eq(4_096)
    expect(cap.call("custom", { "inferenceConfig" => { "maxTokens" => 9 } }, Object.new)).to eq(9)
    unknown = Struct.new(:max_tokens, :context_window).new(nil, 128_000)
    expect([cap.call("openai", {}, unknown), cap.call("openai", {}, Object.new)]).to eq([128_000, 4_096])

    Smith.config.budget_hold_output_tokens = 1_000
    held = Smith::Budget::RequestHold.for_request(provider: "anthropic", model:, messages: text, tools: {},
                                                  schema: nil, params: {})
    asked = Smith::Budget::RequestHold.for_request(provider: "anthropic", model:, messages: text, tools: {},
                                                   schema: nil, params: { max_tokens: 50 })
    expect([held.output_tokens, asked.output_tokens]).to eq([1_000, 50])
    expect { Smith.config.budget_hold_output_tokens = 0 }.to raise_error(ArgumentError)
  end
end
