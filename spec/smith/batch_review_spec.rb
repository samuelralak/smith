# frozen_string_literal: true

# What two reviews of batch mode found (slice 11), each pinned.
RSpec.describe "Smith batch mode: review fixes" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:queue_class) do
    Class.new do
      attr_reader :items

      def initialize = @items = []
      def enqueue(**request) = @items << request
    end
  end
  let(:queue) { queue_class.new }
  let(:server) { SseServer.new }

  around do |example|
    saved_queue = Smith.config.batch_queue
    config = RubyLLM.config
    saved = %i[anthropic_api_key anthropic_api_base].to_h { [_1, config.public_send(_1)] }
    example.run
  ensure
    server.close
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
    Smith.config.batch_queue = saved_queue
  end

  before do
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test"
      config.anthropic_api_base = server.url
    end
    Smith.config.batch_queue = queue
    allow_any_instance_of(workflow_class).to receive(:sleep)
  end

  def message(text, id: "msg_b", tokens: [5, 2])
    { "id" => id, "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
      "content" => [{ "type" => "text", "text" => text }], "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
  end

  def succeeded(text, **) = { "type" => "succeeded", "message" => message(text, **) }

  def errored(type) = { "type" => "errored", "error" => { "type" => "error", "error" => { "type" => type } } }

  def agent(name, register: :spec_review_batch_agent, &body)
    Smith::Agent::Registry.delete(register)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
    end
    klass.class_exec(&body) if body
    klass
  end

  def batching(name, mode: :batch, agent: :spec_review_batch_agent, &body)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "classify this" }] }
      transition :ask, from: :idle, to: :done do
        execute agent, mode:, output_to: :answer
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  def fanning(name, mode: :batch, &body)
    %i[spec_review_detect spec_review_extract].each do |register|
      agent("#{name}#{register.to_s.split("_").last.capitalize}", register:)
    end
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "read" }] }
      transition :read, from: :idle, to: :done do
        fan_out branches: { detect: :spec_review_detect, extract: :spec_review_extract }, mode: mode
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  def resume(klass, key, payload)
    klass.resume!(key, event: :batch_result, token: klass.restore(key, adapter:).awaiting.token, payload:, adapter:)
  end

  it "charges a fan-out branch's paid result that a sibling's failure kept from being taken" do
    ledger = Smith::Budget::Ledger.new(limits: { total_tokens: 1_000 })
    workflow = fanning("SpecReviewFanFail").new(context: {}, ledger:)
    workflow.run!
    detect, extract = queue.items.map { _1[:custom_id] }
    payload = { detect => errored("api_error"), extract => succeeded("paid", tokens: [30, 10]) }
    # A thread that ran a call outside any step keeps the list the step's
    # thread context puts back, which must not carry this step's charges.
    Thread.current[:smith_failed_agent_results] = []

    expect(workflow.resume!(event: :batch_result, token: workflow.awaiting.token, payload:)).to eq(:failed)
    expect(Thread.current[:smith_failed_agent_results]).to eq([])
    charged = workflow.usage_entries.find { _1.branch_key == :extract }
    expect([charged&.mode, charged&.attempt_kind, charged&.input_tokens]).to eq([:batch, :failed_attempt, 30])
    expect(ledger.consumed).to eq(total_tokens: 40)
  end

  it "charges a succeeded result its attempt failed before taking, holds the next attempt to the budget, " \
     "and charges no errored result" do
    failing = false
    agent("SpecReviewUntakenAgent") do
      instructions do
        if failing
          failing = false
          raise Smith::AgentError, "the step failed before its call"
        end
        "Be brief."
      end
    end
    switch = ->(_ctx, attempt) { attempt == 1 ? :batch : :sync }
    klass = batching("SpecReviewUntakenWorkflow", mode: switch) { retry_on attempts: 2, backoff: 1 }
    deliver = lambda do |workflow, result|
      failing = true
      workflow.resume!(event: :batch_result, token: workflow.awaiting.token,
                       payload: { queue.items.last[:custom_id] => result })
    end

    ledger = Smith::Budget::Ledger.new(limits: { total_tokens: 100 })
    paid = klass.new(context: {}, ledger:).tap(&:run!)
    ledger.reconcile!(ledger.reserve!(:total_tokens, 100), 150)
    expect(deliver.call(paid, succeeded("paid", tokens: [30, 10]))).to eq(:failed)
    expect(server.requests).to eq([])
    expect(paid.usage_entries.map { [_1.mode, _1.attempt_kind, _1.input_tokens] })
      .to eq([[:batch, :failed_attempt, 30]])
    expect(ledger.consumed).to eq(total_tokens: 190)

    server.reply(json: message("over the wire", id: "msg_wire"))
    refused = klass.new(context: {}).tap(&:run!)
    expect(deliver.call(refused, errored("api_error"))).to eq(:resumed)
    expect([refused.state, refused.usage_entries.map(&:mode)]).to eq([:done, [nil]])
  end

  it "never lets a later attempt take an earlier attempt's result" do
    server.reply(json: message("over the wire", id: "msg_wire")).reply(json: message("over the wire", id: "msg_w2"))
    switch = ->(_ctx, attempt) { attempt == 1 ? :batch : :sync }
    workflow = fanning("SpecReviewFanRetry", mode: switch) { retry_on attempts: 2, backoff: 1 }.new(context: {})
    workflow.run!
    detect, extract = queue.items.map { _1[:custom_id] }

    workflow.resume!(event: :batch_result, token: workflow.awaiting.token,
                     payload: { detect => errored("api_error"), extract => succeeded("stale") })
    expect(workflow.state).to eq(:done)
    expect(server.requests.length).to eq(2)
    expect(workflow.usage_entries.reject { _1.attempt_kind == :failed_attempt }.map(&:mode)).to eq([nil, nil])
  end

  it "queues nothing and keeps no wait when the step fails after capturing" do
    agent("SpecReviewShapeAgent")
    stamp = Class.new(Smith::Guardrails) do
      define_method(:stamp) { |context| context["stamped"] = true }
      input :stamp
    end
    stamping = with_stubbed_class("SpecReviewStampWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      guardrails stamp
      transition :ask, from: :idle, to: :done do
        execute :spec_review_batch_agent, mode: :batch
        on_failure :fail
      end
    end
    result = stamping.new(context: {}).run_persisted!("run-shape", adapter:)

    expect(result.steps.last[:error]).to be_a(Smith::WorkflowError)
    run = stamping.restore("run-shape", adapter:)
    expect([run.waiting?, run.state, run.to_state[:pending_batch], queue.items]).to eq([false, :failed, nil, []])
  end

  it "runs a strict batch completion as a marked step, and refuses one caught under way" do
    crash = Class.new(Exception) # rubocop:disable Lint/InheritException
    calls = 0
    agent("SpecReviewStrictAgent") do
      define_method(:after_completion) do |content, _context|
        calls += 1
        raise crash if calls == 1

        content
      end
    end
    klass = batching("SpecReviewStrictWorkflow") { nil }
    klass.idempotency_mode :strict
    klass.new(context: {}).run_persisted!("run-strict", adapter:)
    id = queue.items.sole[:custom_id]

    expect { resume(klass, "run-strict", id => succeeded("x")) }.to raise_error(crash)
    expect(JSON.parse(adapter.fetch("run-strict"))["step_in_progress"]).to be(true)
    token = JSON.parse(adapter.fetch("run-strict")).dig("awaiting", "token")
    expect { klass.resume!("run-strict", event: :batch_result, token:, payload: { id => succeeded("x") }, adapter:) }
      .to raise_error(Smith::StepInProgressOnRestore)
  end

  it "refuses a batch in an in-process child before capturing anything" do
    agent("SpecReviewChildAgent")
    child = batching("SpecReviewChildWorkflow")
    parent = with_stubbed_class("SpecReviewParentWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      transition(:nest, from: :idle, to: :done) do
        workflow child
        on_failure :fail
      end
    end

    expect(parent.new(context: {}).run!.state).to eq(:failed)
    expect(queue.items).to eq([])
  end

  it "gives a step that now renders another request the result of the one sent, and traces the change" do
    traces = Smith::Trace::Memory.new
    allow(Smith.config).to receive(:trace_adapter).and_return(traces)
    instructions = "Today is Monday."
    agent("SpecReviewDriftAgent") { instructions { instructions } }
    klass = batching("SpecReviewDriftWorkflow")
    calls = lambda do |workflow|
      workflow.resume!(event: :batch_result, token: workflow.awaiting.token,
                       payload: { queue.items.last[:custom_id] => succeeded("paid") })
      traces.traces.select { _1[:type] == :provider_call }.last[:data]
    end

    same = klass.new(context: {}).tap(&:run!)
    expect(calls.call(same)).not_to have_key(:request_changed)
    drifted = klass.new(context: {}).tap(&:run!)
    instructions = "Today is Tuesday."
    expect(calls.call(drifted).slice(:mode, :outcome, :request_changed))
      .to eq(mode: :batch, outcome: :success, request_changed: true)
    expect([drifted.state, drifted.to_state[:context][:answer]]).to eq([:done, "paid"])
    expect(drifted.usage_entries.map(&:mode)).to eq([:batch])
    expect(Smith::Batch.changed?("0" * 64, { "x" => Float::NAN }, {})).to be(true)
    sent = Smith::Batch.digest(Smith::Batch.request(provider: "anthropic", params: { model: "m" },
                                                    headers: { "anthropic-beta" => "a" }))
    expect([Smith::Batch.changed?(sent, { model: "m" }, { "anthropic-beta" => "a" }),
            Smith::Batch.changed?(sent, { model: "m" }, { "anthropic-beta" => "b" })]).to eq([false, true])
  end

  it "refuses a message that is not of the provider's reply shape, and keeps the wait" do
    agent("SpecReviewShapeCheckAgent")
    workflow = batching("SpecReviewShapeCheckWorkflow").new(context: {})
    workflow.run!
    id = queue.items.sole[:custom_id]
    usage = { "input_tokens" => 1, "output_tokens" => 0 }
    bad = [{ "content" => "not blocks", "usage" => usage }, { "content" => [1], "usage" => usage },
           { "content" => [{ "type" => "text", "text" => 1 }], "usage" => usage },
           { "content" => [], "usage" => { "input_tokens" => -1, "output_tokens" => 0 } },
           { "content" => [], "usage" => { "input_tokens" => 1, "output_tokens" => 0,
                                           "cache_read_input_tokens" => "x" } },
           { "content" => [] }]
    bad.each do |shape|
      payload = { id => { "type" => "succeeded", "message" => shape } }
      expect { workflow.resume!(event: :batch_result, token: workflow.awaiting.token, payload:) }
        .to raise_error(ArgumentError), shape.inspect
    end
    deep = (1..120).reduce({}) { |inner, _| { "x" => inner } }
    expect { workflow.resume!(event: :batch_result, token: workflow.awaiting.token, payload: { id => deep }) }
      .to raise_error(ArgumentError)
    expect(workflow.resume!(event: :batch_result, token: workflow.awaiting.token, payload: { id => succeeded("ok") }))
      .to eq(:resumed)
    expect(Smith::BatchResultFailed.new(kind: "errored", error_type: "x" * 10_000).message.bytesize).to be < 300
  end

  it "restores only a pending batch its step's retry policy and branches allow" do
    agent("SpecReviewRestoreAgent")
    klass = batching("SpecReviewRestoreWorkflow")
    klass.new(context: {}).run_persisted!("run-restore", adapter:)
    stored_state = JSON.parse(adapter.fetch("run-restore"))
    pending = stored_state["pending_batch"]
    restore = ->(changes) { klass.from_state(stored_state.merge("pending_batch" => pending.merge(changes))) }

    expect(restore.call({}).awaiting.attempt).to eq(1)
    bad = [{ "attempt" => 2 }, { "attempt" => 1, "key_generation" => 1 }, { "requests" => { "0" * 64 => "a" * 64 } },
           { "requests" => pending["requests"].transform_values { "nothex" } }]
    bad.each do |changes|
      expect { restore.call(changes) }.to raise_error(Smith::SerializationError), changes.inspect
    end

    retrying = batching("SpecReviewRestoreRetryWorkflow") { retry_on attempts: 2, backoff: 1 }
    retrying.new(context: {}).run_persisted!("run-restore-retry", adapter:)
    retried = JSON.parse(adapter.fetch("run-restore-retry"))
    again = lambda do |changes|
      retrying.from_state(retried.merge("pending_batch" => retried["pending_batch"].merge(changes)))
    end
    expect(again.call("attempt" => 2).awaiting.attempt).to eq(2)
    expect { again.call("attempt" => 2, "key_generation" => 1) }.to raise_error(Smith::SerializationError)

    fanned = fanning("SpecReviewRenamed")
    fanned.new(context: {}).run_persisted!("run-renamed", adapter:)
    stored = JSON.parse(adapter.fetch("run-renamed"))
    renamed = with_stubbed_class("SpecReviewRenamedLater", workflow_class) do
      initial_state :idle
      state :failed
      transition :read, from: :idle, to: :done do
        fan_out branches: { detect: :spec_review_detect, parse: :spec_review_extract }, mode: :batch
        on_failure :fail
      end
    end
    expect { renamed.from_state(stored) }.to raise_error(Smith::SerializationError)
  end

  it "asks a callable object for its mode, and reports a model or tools given by a block as warnings" do
    policy = Class.new { def call(_ctx, attempt) = attempt == 1 ? :batch : :sync }.new
    agent("SpecReviewPolicyAgent")
    batching("SpecReviewPolicyWorkflow", mode: policy).new(context: {}).run!
    expect(queue.items.length).to eq(1)

    agent("SpecReviewBlockAgent") { tools { [] } }
    codes = batching("SpecReviewBlockWorkflow").runtime_readiness.runtime_diagnostics.map { [_1.severity, _1.code] }
    expect(codes).to eq([%i[warning batch_unavailable]])
    Smith::Agent::Registry.delete(:spec_review_batch_agent)
    with_stubbed_class("SpecReviewModelBlockAgent", agent_class) do
      register_as :spec_review_batch_agent
      model { |_context| "claude-sonnet-5-5" }
    end
    codes = batching("SpecReviewModelBlockWorkflow").runtime_readiness.runtime_diagnostics
                                                    .map { [_1.severity, _1.code] }
    expect(codes).to eq([%i[warning batch_unavailable]])
    expect { Smith.config.batch_queue = Object.new }.to raise_error(ArgumentError, /must respond to enqueue/)
  end

  it "refuses credentials in a request's headers, and lets the connection's headers win on submit" do
    expect { Smith::Batch.request(provider: "anthropic", params: {}, headers: { "X-Api-Key" => "k" }) }
      .to raise_error(Smith::WorkflowError, /credentials/)
    server.reply(json: { id: "msgbatch_1" })
    request = Smith::Batch.request(provider: "anthropic", params: { model: "m" },
                                   headers: { "anthropic-version" => "2099-01-01", "anthropic-beta" => "b" })
    Smith::Providers::Anthropic::Batches.new.submit([{ custom_id: "a", request: }])
    headers = server.requests.sole.headers
    expect([headers["anthropic-version"], headers["anthropic-beta"]]).to eq(%w[2023-06-01 b])
  end
end
