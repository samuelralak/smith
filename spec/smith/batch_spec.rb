# frozen_string_literal: true

RSpec.describe "Smith batch mode: a step's requests sent as a batch, and its results taken as replies" do
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
    saved = %i[anthropic_api_key anthropic_api_base openai_api_key].to_h { [_1, config.public_send(_1)] }
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
      config.openai_api_key = "test"
    end
    Smith.config.batch_queue = queue
    allow_any_instance_of(workflow_class).to receive(:sleep)
  end

  def message(text, id: "msg_b", tokens: [5, 2], stop: "end_turn")
    { "id" => id, "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
      "content" => [{ "type" => "text", "text" => text }], "stop_reason" => stop,
      "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
  end

  def succeeded(text, **) = { "type" => "succeeded", "message" => message(text, **) }

  def errored(type) = { "type" => "errored", "error" => { "type" => "error", "error" => { "type" => type } } }

  def agent(name, register: :spec_batch_agent, model: "claude-sonnet-5-5", provider: :anthropic, &body)
    Smith::Agent::Registry.delete(register)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model model, provider:, assume_model_exists: true
    end
    klass.class_exec(&body) if body
    klass
  end

  def batching(name, mode: :batch, &body)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "classify this" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_batch_agent, mode:, output_to: :answer
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  def resume(klass, key, payload)
    klass.resume!(key, event: :batch_result, token: klass.restore(key, adapter:).awaiting.token, payload:, adapter:)
  end

  def only_request = queue.items.sole

  def text_part = { "type" => "text", "text" => "classify this" }

  describe "the declaration" do
    it "takes :sync, :batch or a callable, needs on_failure, is refused when streamed or parallel, and shows" do
      klass = workflow_class
      declare = lambda do |route: true, **options|
        Class.new(klass) do
          state :failed
          transition(:t, from: :a, to: :b) do
            execute :x, **options
            on_failure :fail if route
          end
        end
      end

      expect { declare.call(mode: :later) }.to raise_error(Smith::WorkflowError, /mode: must be :sync, :batch/)
      expect { declare.call(mode: :batch, route: false) }.to raise_error(Smith::WorkflowError, /needs on_failure/)
      expect { declare.call(mode: :sync, route: false) }.not_to raise_error
      expect { declare.call(mode: :batch, stream: :reply) }.to raise_error(Smith::WorkflowError, /cannot stream/)
      expect { declare.call(mode: :sync, stream: :reply) }.not_to raise_error
      expect { declare.call(mode: :batch, parallel: true) }.to raise_error(Smith::WorkflowError, /parallel step/)
      expect([:batch, :sync, -> {}].map { declare.call(mode: _1).graph.transition_snapshots.last.to_h[:mode] })
        .to eq(%i[batch sync callable])
      fanned = Class.new(klass) do
        state :failed
        transition(:t, from: :a, to: :b) do
          fan_out(branches: { one: :x }, mode: :batch)
          on_failure :fail
        end
      end
      expect(fanned.graph.transitions.fetch(:t).batches?).to be(true)
      plain = declare.call(mode: :batch, stream: nil, purpose: :x)
      expect(plain.instance_variable_get(:@transitions).fetch(:t).agent_opts).to eq(purpose: :x)
      expect(declare.call.graph.transitions.fetch(:t).batches?).to be(false)
    end

    it "reports a missing queue, and agents that cannot go in a batch" do
      tool = Class.new(Smith::Tool) { def perform(**) = nil }
      codes = lambda do |name, mode: :batch, **model, &body|
        agent("#{name}Agent", **model) { instance_exec(tool, &body) if body }
        batching("#{name}Workflow", mode:).runtime_readiness.runtime_diagnostics
                                          .select { _1.transition == :ask }.map { [_1.severity, _1.code] }
      end

      expect(codes.call("SpecBatchReady")).to eq([])
      expect(codes.call("SpecBatchTools") { tools _1 }).to eq([%i[error batch_unavailable]])
      expect(codes.call("SpecBatchOpenAI", model: "gpt-4.1", provider: :openai)).to eq([%i[error batch_unavailable]])
      expect(codes.call("SpecBatchInferred", model: "claude-sonnet-5-5", provider: nil)).to eq([])
      expect(codes.call("SpecBatchMaybe", mode: ->(_ctx) { :sync }, model: "gpt-4.1", provider: :openai))
        .to eq([%i[warning batch_unavailable]])
      expect(codes.call("SpecBatchSync", mode: :sync, model: "gpt-4.1", provider: :openai)).to eq([])
      Smith.config.batch_queue = nil
      expect(codes.call("SpecBatchNoQueue")).to eq([%i[error batch_queue_missing]])
    end
  end

  describe Smith::Providers::BatchExchange do
    it "leaves every other provider object's calls on the wire" do
      server.reply(json: message("over the wire", id: "msg_wire"))
      own = RubyLLM::Providers::Anthropic.new(RubyLLM.config)
      chat = RubyLLM.chat(model: "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true)
      chat.add_message(role: :user, content: "hi")

      response = described_class.within(described_class::Exchange.new(own, nil)) { chat.complete }
      expect(response.content).to eq("over the wire")
    end
  end

  describe "Smith::Batch" do
    it "bounds a request, derives a branch's id from the token, and freezes what it checks" do
      stub_const("Smith::Batch::MAX_REQUEST_BYTES", 80)
      expect { Smith::Batch.request(provider: "anthropic", params: { text: "x" * 100 }, headers: {}) }
        .to raise_error(Smith::WorkflowError, /past the 80/)
      token = "a" * 64
      expect(Smith::Batch.custom_id(token)).to eq(token)
      expect(Smith::Batch.custom_id(token, :detect)).to eq(Digest::SHA256.hexdigest("#{token}/detect"))
      expect(Smith::Batch.custom_id(token, :detect)).not_to eq(Smith::Batch.custom_id(token, :extract))
      results = Smith::Batch.results!({ token => { type: "succeeded", message: { id: "m" } } }, [token])
      expect(results).to eq(token => { "type" => "succeeded", "message" => { "id" => "m" } })
      expect(results[token]["message"]).to be_frozen
      stub_const("Smith::Batch::MAX_RESULTS_BYTES", 10)
      expect { Smith::Batch.results!({ token => { type: "canceled" } }, [token]) }
        .to raise_error(ArgumentError, /bytes/)
    end

    it "is reported when an in-process child would wait for one" do
      agent("SpecBatchChildAgent")
      child = batching("SpecBatchChildWorkflow")
      parent = with_stubbed_class("SpecBatchParentWorkflow", workflow_class) do
        initial_state :idle
        transition(:nest, from: :idle, to: :done) { workflow child }
      end

      expect(parent.runtime_readiness.runtime_diagnostics.map(&:code)).to include(:nested_workflow_waits)
    end
  end

  describe "sending" do
    it "hands the request a synchronous call would post to the queue, and waits for its result" do
      agent("SpecBatchSendAgent")
      workflow = batching("SpecBatchSendWorkflow").new(context: {})

      expect(workflow.run_persisted!("run-1", adapter:).steps).to eq([])
      wait = workflow.awaiting
      expect([wait.kind, wait.event, wait.children, wait.attempt]).to eq([:batch, :batch_result, 1, 1])
      expect(only_request.slice(:custom_id, :await_token, :execution_key))
        .to eq(custom_id: wait.token, await_token: wait.token, execution_key: "run-1")
      request = only_request[:request]
      expect(request.slice("provider", "headers")).to eq("provider" => "anthropic", "headers" => {})
      expect(request["params"]).to include("model" => "claude-sonnet-5-5", "stream" => false,
                                           "messages" => [{ "role" => "user", "content" => [text_part] }])
      expect(request).to be_frozen
      expect(server.requests).to eq([])
      expect(adapter.fetch("run-1")).to include('"kind":"batch"', '"pending_batch":{"transition":"ask","attempt":1')
    end

    it "refuses before sending anything: over budget, a wait past the TTL, an agent that reached no provider" do
      agent("SpecBatchGateAgent")
      over = Smith::Budget::Ledger.new(limits: { total_tokens: 10 }, consumed: { total_tokens: 15 })
      expect(batching("SpecBatchOverWorkflow").new(context: {}, ledger: over).run!.steps.last[:error])
        .to be_a(Smith::BudgetExceeded)
      short = batching("SpecBatchTtlWorkflow")
      short.persistence_ttl 3600
      expect(short.new(context: {}).run_persisted!("run-ttl", adapter:).steps.last[:error].message)
        .to include("persistence TTL")
      silent = batching("SpecBatchSilentWorkflow").new(context: {})
      silent.define_singleton_method(:invoke_agent) { |*| "no call" }
      expect(silent.run!.steps.last[:error]).to be_a(Smith::BatchModeUnavailable)
      expect(queue.items).to eq([])
    end

    it "asks a one-argument mode callable, and refuses an answer other than :sync or :batch" do
      agent("SpecBatchAskAgent")
      expect(batching("SpecBatchAskWorkflow", mode: ->(ctx) { ctx[:later] ? :batch : :sync })
               .new(context: { later: true }).run!.steps).to eq([])
      expect(queue.items.length).to eq(1)
      wrong = batching("SpecBatchWrongWorkflow", mode: ->(_ctx) { :later }).new(context: {}).run!
      expect(wrong.steps.last[:error].message).to include("must return :sync or :batch, got :later")
    end

    it "refuses before sending anything: no queue, no batch interface, tools, inside split-step execution" do
      tool = Class.new(Smith::Tool) { def perform(**) = nil }
      failure = lambda do |name, **model, &body|
        agent("#{name}Agent", **model, &body)
        batching("#{name}Workflow").new(context: {}).run!.steps.last[:error]
      end

      expect(failure.call("SpecBatchOpenAIRun", model: "gpt-4.1", provider: :openai))
        .to be_a(Smith::BatchModeUnavailable)
      expect(failure.call("SpecBatchToolsRun") { tools tool }.message).to include("cannot have tools")
      Smith.config.batch_queue = nil
      expect(failure.call("SpecBatchNoQueueRun")).to be_a(Smith::BatchQueueMissing)
      expect(queue.items).to eq([])

      Smith.config.batch_queue = queue
      holder = {}
      agent("SpecBatchSplitAgent")
      split_input = lambda do |_ctx|
        holder.fetch(:workflow).instance_variable_set(:@split_step_phase, :executing)
        [{ role: :user, content: "x" }]
      end
      klass = with_stubbed_class("SpecBatchSplitWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition(:ask, from: :idle, to: :done) do
          execute :spec_batch_agent, mode: :batch, input: split_input
          on_failure :fail
        end
      end
      holder[:workflow] = klass.new(context: {})
      expect(holder[:workflow].advance![:error].message).to include("cannot wait inside split-step execution")
      expect([holder[:workflow].waiting?, queue.items]).to eq([false, []])
    end
  end

  describe "completing" do
    it "takes the result as the reply: output_to, usage with mode :batch, its facts, the batch discount" do
      catalog = { %w[anthropic claude-sonnet-5-5] => { input_cost_per_token: 0.001, output_cost_per_token: 0.002,
                                                       batch_discount: 0.5 } }
      allow(Smith.config).to receive(:pricing).and_return(catalog)
      agent("SpecBatchDoneAgent")
      klass = batching("SpecBatchDoneWorkflow")
      klass.new(context: {}).run_persisted!("run-2", adapter:)

      expect(resume(klass, "run-2", only_request[:custom_id] => succeeded("positive"))).to eq(:resumed)
      run = klass.restore("run-2", adapter:)
      entry = run.to_state[:usage_entries].sole
      expect([run.state, run.to_state[:context][:answer], run.to_state[:pending_batch], run.to_state[:step_count]])
        .to eq([:done, "positive", nil, 1])
      expect(entry.slice(:mode, :stop_reason, :provider_message_id, :input_tokens, :output_tokens))
        .to eq(mode: :batch, stop_reason: "end_turn", provider_message_id: "msg_b", input_tokens: 5, output_tokens: 2)
      expect(entry[:cost]).to be_within(1e-9).of(0.0045)
      expect(server.requests).to eq([])
    end

    it "makes a follow-up call over the wire, as after a synchronous call" do
      schema = Class.new do
        def to_json_schema
          { name: "v", schema: { type: "object", required: ["label"], properties: { label: { type: "string" } } } }
        end
      end
      agent("SpecBatchRepairAgent") { output_schema schema }
      server.reply(json: message('{"label":"positive"}', id: "msg_repair"))
      klass = batching("SpecBatchRepairWorkflow")
      klass.new(context: {}).run_persisted!("run-3", adapter:)

      expect(resume(klass, "run-3", only_request[:custom_id] => succeeded("not json"))).to eq(:resumed)
      run = klass.restore("run-3", adapter:)
      expect(run.to_state[:context][:answer]).to eq(label: "positive")
      expect(run.to_state[:usage_entries].map { _1[:mode] }).to eq([:batch, nil])
      expect(server.requests.sole.path).to eq("/v1/messages")
    end

    it "fails on a refused request without retrying, and retries a failed or missing result" do
      agent("SpecBatchFailAgent")
      invalid = batching("SpecBatchInvalidWorkflow") { retry_on attempts: 3, backoff: 1 }
      invalid.new(context: {}).run_persisted!("run-4", adapter:)
      expect(resume(invalid, "run-4", only_request[:custom_id] => errored("invalid_request_error"))).to eq(:failed)
      expect(invalid.restore("run-4", adapter:).to_state[:last_failed_step]).to include(error_class: "Smith::BatchRequestInvalid")
      expect(queue.items.length).to eq(1)

      queue.items.clear
      retried = batching("SpecBatchRetriedWorkflow") { retry_on attempts: 2, backoff: 1 }
      retried.new(context: {}).run_persisted!("run-5", adapter:)
      first = only_request[:custom_id]
      expect(resume(retried, "run-5", first => errored("overloaded_error"))).to eq(:resumed)
      run = retried.restore("run-5", adapter:)
      expect([run.awaiting.attempt, queue.items.length, run.awaiting.token == first]).to eq([2, 2, false])
      expect(resume(retried, "run-5", queue.items.last[:custom_id] => succeeded("ok"))).to eq(:resumed)
      expect(retried.restore("run-5", adapter:).state).to eq(:done)

      %w[canceled expired].each do |type|
        error = Smith::Batch.message!({ "type" => type }) rescue $ERROR_INFO # rubocop:disable Style/RescueModifier
        expect([error.class, error.kind]).to eq([Smith::BatchResultFailed, type])
      end
      expect(Smith::Errors.retryable?(Smith::BatchResultFailed.new(kind: "missing"))).to be(true)
      expect(Smith::Errors.retryable?(Smith::BatchRequestInvalid.new)).to be(false)
    end

    it "lets a mode callable send the retry synchronously, and a durable retry wait its backoff" do
      server.reply(json: message("synced", id: "msg_sync"))
      agent("SpecBatchSwitchAgent")
      attempts = []
      switch = lambda do |_ctx, attempt|
        attempts << attempt
        attempt == 1 ? :batch : :sync
      end
      switched = batching("SpecBatchSwitchWorkflow", mode: switch) { retry_on attempts: 2, backoff: 1 }
      switched.new(context: {}).run_persisted!("run-6", adapter:)
      expect(resume(switched, "run-6", only_request[:custom_id] => errored("api_error"))).to eq(:resumed)
      run = switched.restore("run-6", adapter:)
      expect([run.state, run.to_state[:context][:answer], attempts]).to eq([:done, "synced", [1, 2]])
      expect(run.to_state[:usage_entries].map { _1[:mode] }).to eq([nil])

      queue.items.clear
      durable = batching("SpecBatchDurableWorkflow") { retry_on attempts: 2, backoff: 30, durable: true }
      durable.new(context: {}).run_persisted!("run-7", adapter:)
      expect(resume(durable, "run-7", only_request[:custom_id] => errored("api_error"))).to eq(:resumed)
      waiting = durable.restore("run-7", adapter:)
      expect([waiting.awaiting.kind, waiting.to_state[:pending_batch], waiting.to_state[:pending_retry]["attempt"]])
        .to eq([:retry, nil, 2])
    end

    it "records the key generation a settled failure moves the retry to" do
      agent("SpecBatchGenerationAgent")
      klass = batching("SpecBatchGenerationWorkflow") do
        retry_on attempts: 2, backoff: 1, new_idempotency_key_on: [Smith::BatchResultFailed]
      end
      klass.new(context: {}).run_persisted!("run-gen", adapter:)
      expect(resume(klass, "run-gen", only_request[:custom_id] => errored("api_error"))).to eq(:resumed)
      expect(klass.restore("run-gen", adapter:).to_state[:pending_batch])
        .to eq("transition" => "ask", "attempt" => 2, "key_generation" => 1)
    end

    it "keeps the wait when a delivery crashes, and finishes a durable retry's batch cleanly" do
      crash = Class.new(Exception) # rubocop:disable Lint/InheritException
      agent("SpecBatchCrashAgent") { define_method(:after_completion) { |_content, _context| raise crash } }
      crashing = batching("SpecBatchCrashWorkflow").new(context: {})
      crashing.run!
      token = crashing.awaiting.token
      expect { crashing.resume!(event: :batch_result, token:, payload: { token => succeeded("x") }) }
        .to raise_error(crash)
      expect([crashing.waiting?, crashing.awaiting.token]).to eq([true, token])

      queue.items.clear
      agent("SpecBatchCycleAgent")
      cycle = batching("SpecBatchCycleWorkflow") { retry_on attempts: 2, backoff: 30, durable: true }
      cycle.new(context: {}).run_persisted!("run-cycle", adapter:)
      resume(cycle, "run-cycle", only_request[:custom_id] => errored("api_error"))
      wait = cycle.restore("run-cycle", adapter:).awaiting
      expect(cycle.expire_wait!("run-cycle", token: wait.token, now: wait.deadline_at, adapter:)).to eq(:expired)
      cycle.restore("run-cycle", adapter:).run_persisted!("run-cycle", adapter:)
      expect(resume(cycle, "run-cycle", queue.items.last[:custom_id] => succeeded("done"))).to eq(:resumed)
      finished = cycle.restore("run-cycle", adapter:)
      expect([finished.state, finished.to_state[:pending_retry], finished.to_state[:pending_batch]])
        .to eq([:done, nil, nil])
    end

    it "fails a wait past its deadline as a missing result, and leaves a bad delivery's wait to a good one" do
      agent("SpecBatchLateAgent")
      klass = batching("SpecBatchLateWorkflow")
      klass.new(context: {}).run_persisted!("run-8", adapter:)
      wait = klass.restore("run-8", adapter:).awaiting
      expect(klass.expire_wait!("run-8", token: wait.token, now: wait.deadline_at - 1, adapter:)).to eq(:not_due)
      expect(klass.expire_wait!("run-8", token: wait.token, now: wait.deadline_at, adapter:)).to eq(:expired)
      expect(klass.restore("run-8", adapter:).to_state[:last_failed_step]).to include(error_class: "Smith::BatchResultFailed")

      queue.items.clear
      klass.new(context: {}).run_persisted!("run-9", adapter:)
      id = only_request[:custom_id]
      workflow = klass.restore("run-9", adapter:)
      [{}, { id => { "type" => "won" } }, { id => { "type" => "succeeded" } },
       { id => succeeded("x"), "other" => succeeded("y") }, { ("0" * 64) => succeeded("x") },
       [id], { id => succeeded("\xFF".b) }].each do |payload|
        expect { workflow.resume!(event: :batch_result, token: workflow.awaiting.token, payload:) }
          .to raise_error(ArgumentError), payload.inspect
      end
      expect(workflow.resume!(event: :batch_result, token: "0" * 64, payload: {})).to eq(:stale)
      expect(workflow.resume!(event: :other, token: workflow.awaiting.token, payload: {})).to eq(:stale)
      expect(workflow.resume!(event: :batch_result, token: workflow.awaiting.token, payload: { id => succeeded("x") }))
        .to eq(:resumed)
    end

    it "charges a result that comes after the budget ran out, which a fresh call could not spend" do
      agent("SpecBatchBudgetAgent")
      ledger = Smith::Budget::Ledger.new(limits: { total_tokens: 100 })
      workflow = batching("SpecBatchBudgetWorkflow").new(context: {}, ledger:)
      workflow.run!
      expect(ledger.consumed.fetch(:total_tokens, 0)).to eq(0)
      other = ledger.reserve!(:total_tokens, 100)
      ledger.reconcile!(other, 150)

      expect(workflow.resume!(event: :batch_result, token: workflow.awaiting.token,
                              payload: { only_request[:custom_id] => succeeded("late", tokens: [10, 4]) }))
        .to eq(:resumed)
      expect([workflow.state, ledger.consumed]).to eq([:done, { total_tokens: 164 }])
      expect { ledger.reserve!(:total_tokens, 1) }.to raise_error(Smith::BudgetExceeded)
    end
  end

  describe "a fan-out" do
    it "captures each branch's request in its branch, waits once, and gives each branch its own result" do
      %i[spec_detect spec_extract].each do |name|
        agent("Spec#{name.to_s.split("_").last.capitalize}Agent", register: name)
      end
      klass = with_stubbed_class("SpecBatchFanWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "read" }] }
        transition :read, from: :idle, to: :done do
          fan_out branches: { detect: :spec_detect, extract: :spec_extract }, mode: :batch, output_to: :read
          on_failure :fail
        end
      end
      klass.new(context: {}).run_persisted!("run-10", adapter:)
      wait = klass.restore("run-10", adapter:).awaiting
      ids = queue.items.map { _1[:custom_id] }
      expect([wait.children, queue.items.map { _1[:await_token] }.uniq, ids.uniq.length]).to eq([2, [wait.token], 2])
      expect(ids).to eq(%w[detect extract].map { Smith::Batch.custom_id(wait.token, _1.to_sym) })

      expect(resume(klass, "run-10", ids.first => succeeded("clean"), ids.last => succeeded("fields"))).to eq(:resumed)
      run = klass.restore("run-10", adapter:)
      expect(run.to_state[:context][:read].map { |branch| [branch[:branch], branch[:output]] })
        .to eq([%w[detect clean], %w[extract fields]])
      expect(run.to_state[:usage_entries].map { [_1[:branch_key], _1[:mode]] })
        .to contain_exactly(%i[detect batch], %i[extract batch])
    end
  end

  describe "restoring" do
    it "refuses a pending batch or batch wait the class no longer allows, or that is malformed" do
      agent("SpecBatchRestoreAgent")
      klass = batching("SpecBatchRestoreWorkflow")
      klass.new(context: {}).run_persisted!("run-11", adapter:)
      state = JSON.parse(adapter.fetch("run-11"))
      restore = ->(changes) { klass.from_state(state.merge(changes)) }

      expect(restore.call({}).awaiting.kind).to eq(:batch)
      [nil, { "transition" => "ask", "attempt" => 0, "key_generation" => 0 },
       { "transition" => "ask", "attempt" => 1, "key_generation" => 1 },
       { "transition" => "other", "attempt" => 1, "key_generation" => 0 },
       { "transition" => "ask", "attempt" => 1, "key_generation" => 0, "extra" => 1 }].each do |pending|
        expect { restore.call("pending_batch" => pending) }.to raise_error(Smith::SerializationError), pending.inspect
      end
      expect { restore.call("awaiting" => state["awaiting"].merge("children" => 2)) }
        .to raise_error(Smith::UnknownTransitionOnRestore)
      [0, "1", 10_001].each do |count|
        expect { restore.call("awaiting" => state["awaiting"].merge("children" => count)) }
          .to raise_error(Smith::SerializationError), count.inspect
      end
      expect { restore.call("awaiting" => state["awaiting"].merge("event" => "other")) }
        .to raise_error(Smith::SerializationError)
      synced = batching("SpecBatchNowSyncWorkflow", mode: :sync)
      expect { synced.from_state(state) }.to raise_error(Smith::UnknownTransitionOnRestore)
    end
  end
end
