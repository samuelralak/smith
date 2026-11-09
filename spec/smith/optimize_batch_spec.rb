# frozen_string_literal: true

require "json"

# Batch mode on an `optimize` step: each of the loop's calls (a round's
# generator, then its evaluator) goes as a batch request of its own, and the
# step waits for its result before the next, the loop's progress kept with
# the wait, so a delivery goes on from where the loop stood.
RSpec.describe "Smith batch mode on an optimize step" do
  include EveryStoreAdapter

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
  let(:verdict_schema) do
    Class.new do
      def to_json_schema
        { name: "verdict", schema: { type: "object", required: %w[accept feedback],
                                     properties: { accept: { type: "boolean" }, feedback: { type: "string" } } } }
      end
    end
  end

  around do |example|
    saved_queue = Smith.config.batch_queue
    config = RubyLLM.config
    saved = %i[anthropic_api_key anthropic_api_base openai_api_key max_retries].to_h { [_1, config.public_send(_1)] }
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
      config.max_retries = 0
    end
    Smith.config.batch_queue = queue
    allow_any_instance_of(workflow_class).to receive(:sleep)
    agent("SpecOptBatchWriter", :spec_opt_batch_writer)
    agent("SpecOptBatchJudge", :spec_opt_batch_judge)
  end

  def message(text, id: "msg_b", tokens: [5, 2])
    { "id" => id, "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
      "content" => [{ "type" => "text", "text" => text }], "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
  end

  def succeeded(text, **) = { "type" => "succeeded", "message" => message(text, **) }

  def verdict(accept, feedback = "ok") = succeeded(JSON.generate(accept:, feedback:))

  def agent(name, register, model: "claude-sonnet-5-5", provider: :anthropic)
    Smith::Agent::Registry.delete(register)
    with_stubbed_class(name, agent_class) do
      register_as register
      model model, provider:, assume_model_exists: true
    end
  end

  # The step drafts a line in up to `max_rounds` rounds, its writer and judge
  # batched as `mode` says.
  def drafting(name, mode: :batch, max_rounds: 2, idempotency: :lax, **optimize, &body)
    schema = verdict_schema
    with_stubbed_class(name, workflow_class) do
      idempotency_mode idempotency
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "write a line" }] }
      transition :draft, from: :idle, to: :done do
        optimize generator: :spec_opt_batch_writer, evaluator: :spec_opt_batch_judge, max_rounds:,
                 evaluator_schema: schema, mode:, output_to: :draft, **optimize
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  def last_request = queue.items.last

  def request_texts(item)
    item[:request]["params"]["messages"].map { |turn| turn["content"].map { _1["text"] }.join }
  end

  # Delivers the waiting call's result through the store: the class-level
  # `resume!` where the store checks versions, else a restored run's own
  # `resume!`, stored after.
  def deliver(klass, key, store, result)
    run = klass.restore(key, adapter: store)
    token = run.awaiting.token
    payload = { token => result }
    return klass.resume!(key, event: :batch_result, token:, payload:, adapter: store) if
      Smith::PersistenceAdapters.supports?(store, :store_versioned)

    run.resume!(event: :batch_result, token:, payload:).tap { run.persist!(key, adapter: store) }
  end

  describe "the declaration" do
    it "takes :sync, :batch or a callable and on_request_change:, needs on_failure, and shows in the graph" do
      snapshot = drafting("SpecOptBatchDeclaredWorkflow", on_request_change: :fail).graph.transition_snapshots.last.to_h
      expect(snapshot.slice(:mode, :on_request_change)).to eq(mode: :batch, on_request_change: :fail)
      expect(drafting("SpecOptBatchCallableWorkflow", mode: ->(_context) { :sync })
               .graph.transition_snapshots.last.to_h[:mode]).to eq(:callable)
      expect(drafting("SpecOptBatchSyncWorkflow", mode: :sync).graph.transitions.fetch(:draft).batches?).to be(false)
      klass = workflow_class
      schema = verdict_schema
      expect do
        Class.new(klass) do
          transition :t, from: :a, to: :b do
            optimize generator: :w, evaluator: :j, max_rounds: 2, evaluator_schema: schema, mode: :batch
          end
        end
      end.to raise_error(Smith::WorkflowError, /mode: :batch needs on_failure/)
      expect do
        Class.new(klass) do
          transition :t, from: :a, to: :b do
            optimize generator: :w, evaluator: :j, max_rounds: 2, evaluator_schema: schema, mode: :later
            on_failure :fail
          end
        end
      end.to raise_error(Smith::WorkflowError, /mode: must be :sync, :batch/)
    end

    it "reports a generator or an evaluator that cannot go in a batch" do
      agent("SpecOptBatchOpenAIJudge", :spec_opt_batch_judge, model: "gpt-4.1", provider: :openai)
      diagnostics = drafting("SpecOptBatchReportWorkflow").runtime_readiness.runtime_diagnostics
                                                          .select { _1.transition == :draft }

      found = diagnostics.map { [_1.severity, _1.code, _1.target] }
      expect(found).to eq([%i[error batch_unavailable spec_opt_batch_judge]])
    end
  end

  describe "a loop of batched calls" do
    %i[lax strict].each do |idempotency|
      it "waits for each call in turn and goes on from where the loop stood, in #{idempotency} mode, in every store" do
        klass = drafting("SpecOptBatchLoop#{idempotency.capitalize}Workflow", idempotency:)

        every_store_adapter.each do |name, store|
          queue.items.clear
          key = "opt-loop-#{idempotency}-#{name}"
          klass.new(context: {}).run_persisted!(key, adapter: store)
          expect(request_texts(last_request)).to eq(["write a line"]), name.to_s

          expect(deliver(klass, key, store, succeeded("first line"))).to eq(:resumed)
          expect(request_texts(last_request)).to eq(["first line"]), name.to_s
          expect(last_request[:request]["params"]).to include("output_config")

          expect(deliver(klass, key, store, verdict(false, "shorter"))).to eq(:resumed)
          expect(request_texts(last_request).last).to include("[smith:evaluator-feedback]\nshorter"), name.to_s

          expect(deliver(klass, key, store, succeeded("line"))).to eq(:resumed)
          expect(deliver(klass, key, store, verdict(true))).to eq(:resumed)

          run = klass.restore(key, adapter: store)
          entries = run.to_state[:usage_entries]
          expect([run.state, run.to_state[:context][:draft], run.to_state[:pending_batch]])
            .to eq([:done, "line", nil]), name.to_s
          rounds = entries.map { _1.values_at(:mode, :round) }
          expect(rounds).to eq([[:batch, 0], [:batch, 0], [:batch, 1], [:batch, 1]]), name.to_s
          expect([queue.items.length, queue.items.map { _1[:custom_id] }.uniq.length]).to eq([4, 4])
          expect(server.requests).to eq([]), name.to_s
        end
      end
    end

    it "keeps the loop's progress with each wait: the round, the call it waits for, the candidate and feedback" do
      klass = drafting("SpecOptBatchProgressWorkflow")
      klass.new(context: {}).run_persisted!("opt-progress", adapter:)
      stored = -> { JSON.parse(adapter.fetch("opt-progress"))["pending_batch"]["progress"] }

      expect(stored.call).to include("round" => 0, "role" => "generator", "candidate" => nil)
      deliver(klass, "opt-progress", adapter, succeeded("first line"))
      expect(stored.call).to include("round" => 0, "role" => "evaluator", "candidate" => "first line")
      deliver(klass, "opt-progress", adapter, verdict(false, "shorter"))
      expect(stored.call).to include("round" => 1, "role" => "generator", "candidate" => "first line",
                                     "feedback" => "shorter")
      expect(stored.call["evaluations"]).to eq(
        "1" => [{ "round" => 0, "source" => "evaluator", "verdict" => { "accept" => false, "feedback" => "shorter" } }]
      )
    end

    it "runs before_eval once a round, and hands callables every verdict so far, across waits" do
      seen = []
      exhausted = lambda do |state|
        seen << state.evaluations.map { _1.slice(:round, :source) }
        state.candidate
      end
      ran = []
      klass = drafting("SpecOptBatchCallablesWorkflow", on_exhaustion: exhausted,
                                                        before_eval: ->(state, _context) { ran << state.candidate })
      klass.new(context: {}).run_persisted!("opt-callables", adapter:)
      ["one", verdict(false, "again"), "two", verdict(false, "still")].each do |result|
        deliver(klass, "opt-callables", adapter, result.is_a?(String) ? succeeded(result) : result)
      end

      expect(ran).to eq(%w[one two])
      expect(seen).to eq([[{ round: 0, source: :evaluator }, { round: 1, source: :evaluator }]])
      expect(klass.restore("opt-callables", adapter:).to_state[:context][:draft]).to eq("two")
    end

    it "asks a mode callable at each call, and sends a call it says :sync over the wire" do
      server.reply(json: message(JSON.generate(accept: true, feedback: "ok"), id: "msg_sync"))
      calls = []
      mode = lambda do |context, attempt|
        calls << attempt
        context[:drafted] ? :sync : :batch
      end
      klass = drafting("SpecOptBatchMixedWorkflow", mode:, before_eval: lambda { |_state, context|
        context[:drafted] = true
      })
      klass.new(context: {}).run_persisted!("opt-mixed", adapter:)
      deliver(klass, "opt-mixed", adapter, succeeded("line"))

      run = klass.restore("opt-mixed", adapter:)
      expect([run.state, run.to_state[:context][:draft], calls]).to eq([:done, "line", [1, 1]])
      expect(run.to_state[:usage_entries].map { _1[:mode] }).to eq([:batch, nil])
      expect(server.requests.sole.path).to eq("/v1/messages")
    end
  end

  describe "failing and falling back" do
    it "fails a call whose wait passed its deadline, and a retry runs the loop afresh as its mode says" do
      server.reply(json: message("wired line", id: "msg_w1"))
      server.reply(json: message(JSON.generate(accept: true, feedback: "ok"), id: "msg_w2"))
      mode = ->(_context, attempt) { attempt == 1 ? :batch : :sync }
      klass = drafting("SpecOptBatchFallbackWorkflow", mode:) { retry_on Smith::BatchResultFailed, attempts: 2 }
      klass.new(context: {}).run_persisted!("opt-fallback", adapter:)
      deliver(klass, "opt-fallback", adapter, succeeded("batched line"))
      wait = klass.restore("opt-fallback", adapter:).awaiting

      expect(klass.expire_wait!("opt-fallback", token: wait.token, now: wait.deadline_at, adapter:)).to eq(:expired)
      run = klass.restore("opt-fallback", adapter:)
      expect([run.state, run.to_state[:context][:draft]]).to eq([:done, "wired line"])
      expect(run.to_state[:usage_entries].map { _1[:mode] }).to eq([:batch, nil, nil])
      expect(server.requests.length).to eq(2)
    end

    it "fails without a retry through on_failure, its last failed step the call's" do
      klass = drafting("SpecOptBatchFailedWorkflow")
      klass.new(context: {}).run_persisted!("opt-failed", adapter:)
      errored = { "type" => "errored", "error" => { "type" => "error", "error" => { "type" => "api_error" } } }

      expect(deliver(klass, "opt-failed", adapter, errored)).to eq(:failed)
      expect(klass.restore("opt-failed", adapter:).to_state[:last_failed_step])
        .to include(transition: :draft, error_class: "Smith::BatchResultFailed")
    end

    it "keeps the stored wait when a delivery crashes, and a second delivery goes on as the first would have" do
      crash = Class.new(Exception) # rubocop:disable Lint/InheritException
      crashes = [true]
      klass = drafting("SpecOptBatchCrashWorkflow", before_eval: ->(_s, _c) { raise crash if crashes.shift })
      klass.new(context: {}).run_persisted!("opt-crash", adapter:)
      token = klass.restore("opt-crash", adapter:).awaiting.token

      expect { deliver(klass, "opt-crash", adapter, succeeded("line")) }.to raise_error(crash)
      stored = klass.restore("opt-crash", adapter:)
      expect([stored.awaiting.token, stored.to_state[:pending_batch]["progress"]["role"]]).to eq([token, "generator"])
      expect(deliver(klass, "opt-crash", adapter, succeeded("line"))).to eq(:resumed)
      run = klass.restore("opt-crash", adapter:)
      expect(run.to_state[:pending_batch]["progress"]).to include("role" => "evaluator", "candidate" => "line")
      expect([run.to_state[:usage_entries].length, queue.items.length]).to eq([1, 2])
    end
  end

  describe "strict mode" do
    it "stores a delivery as a step under way, so a crashed one is the host's to decide, as on any batch step" do
      crash = Class.new(Exception) # rubocop:disable Lint/InheritException
      klass = drafting("SpecOptBatchStrictCrashWorkflow", idempotency: :strict,
                                                          before_eval: ->(_state, _context) { raise crash })
      klass.new(context: {}).run_persisted!("opt-strict-crash", adapter:)

      expect { deliver(klass, "opt-strict-crash", adapter, succeeded("line")) }.to raise_error(crash)
      expect(JSON.parse(adapter.fetch("opt-strict-crash"))["step_in_progress"]).to be(true)
      expect { deliver(klass, "opt-strict-crash", adapter, succeeded("line")) }
        .to raise_error(Smith::StepInProgressOnRestore)
    end
  end

  describe "a result whose request changed, and a progress too large to store" do
    it "resends a call whose request changed over the wire, and the loop batches its next call" do
      day = +"Monday"
      Smith::Agent::Registry.delete(:spec_opt_batch_writer)
      with_stubbed_class("SpecOptBatchDatedWriter", agent_class) do
        register_as :spec_opt_batch_writer
        model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
        instructions { "Today is #{day}." }
      end
      server.reply(json: message("a Tuesday line", id: "msg_wire"))
      klass = drafting("SpecOptBatchChangedWorkflow", on_request_change: :resend)
      klass.new(context: {}).run_persisted!("opt-changed", adapter:)
      day.replace("Tuesday")

      expect(deliver(klass, "opt-changed", adapter, succeeded("a Monday line"))).to eq(:resumed)
      run = klass.restore("opt-changed", adapter:)
      expect(run.to_state[:pending_batch]["progress"])
        .to include("role" => "evaluator", "candidate" => "a Tuesday line")
      expect(run.to_state[:usage_entries].map { _1.values_at(:mode, :attempt_kind) })
        .to contain_exactly(%i[batch failed_attempt], [nil, :completed_attempt])
      expect(server.requests.sole.body.to_json).to include("Today is Tuesday.")
    end

    it "fails the step before queueing a call whose progress would take the run past persistence_max_bytes" do
      saved = Smith.config.persistence_max_bytes
      Smith.config.persistence_max_bytes = 16_384
      klass = drafting("SpecOptBatchLargeWorkflow")
      klass.new(context: {}).run_persisted!("opt-large", adapter:)

      expect(deliver(klass, "opt-large", adapter, succeeded("x" * 12_000))).to eq(:failed)
      expect(klass.restore("opt-large", adapter:).to_state[:last_failed_step])
        .to include(error_class: "Smith::PersistedStateTooLarge")
      expect(queue.items.length).to eq(1)
    ensure
      Smith.config.persistence_max_bytes = saved
    end
  end

  describe "budgets" do
    it "settles a delivered call's hold before the next call is held, so a capped ledger takes the next" do
      saved = Smith.config.budget_hold_output_tokens
      Smith.config.budget_hold_output_tokens = 1_000
      Smith.config.pricing = { %w[anthropic claude-sonnet-5-5] => { input_cost_per_token: 0.000003,
                                                                    output_cost_per_token: 0.000015 } }
      holds = {}
      spent = [0]
      capped = Class.new do
        define_method(:reserve!) do |amount, key:, expires_at:|
          admitted = holds.values.sum + spent.first + amount.tokens <= 1_500
          holds[key] = amount.tokens if admitted
          admitted && expires_at && true
        end
        define_method(:reconcile!) { |key, amount| holds.delete(key) && (spent[0] += amount.tokens) }
        define_method(:release!) { |key| holds.delete(key) }
      end.new
      klass = drafting("SpecOptBatchCappedWorkflow")
      klass.budget_ledger { |_context| capped }
      workflow = klass.new(context: {})
      workflow.run!
      token = workflow.awaiting.token

      expect(workflow.resume!(event: :batch_result, token:, payload: { token => succeeded("line") })).to eq(:resumed)
      expect([workflow.waiting?, workflow.to_state[:pending_batch]["progress"]["role"]]).to eq([true, "evaluator"])
      expect(holds.keys).to eq([workflow.awaiting.token])
    ensure
      Smith.config.budget_hold_output_tokens = saved
      Smith.config.pricing = nil
    end

    it "charges each result once, as it comes, and holds each request on a host's ledger until its result" do
      ledger = Smith::Budget::Ledger.new(limits: { total_tokens: 1_000 })
      workflow = drafting("SpecOptBatchBudgetWorkflow").new(context: {}, ledger:)
      workflow.run!
      [succeeded("line", tokens: [10, 4]), verdict(true)].each do |result|
        workflow.resume!(event: :batch_result, token: workflow.awaiting.token,
                         payload: { workflow.awaiting.token => result })
      end

      expect([workflow.state, ledger.consumed]).to eq([:done, { total_tokens: 21 }])
    end

    it "holds each call's request under its custom_id, and settles it when its result comes" do
      calls = []
      host = Class.new do
        define_method(:reserve!) { |_amount, key:, expires_at:| (calls << [:reserve, key]) && expires_at && true }
        define_method(:reconcile!) { |key, _amount| calls << [:reconcile, key] }
        define_method(:release!) { |key| calls << [:release, key] }
      end.new
      klass = drafting("SpecOptBatchHeldWorkflow") { nil }
      klass.budget_ledger { |_context| host }
      Smith.config.pricing = { %w[anthropic claude-sonnet-5-5] => { input_cost_per_token: 0.000003,
                                                                    output_cost_per_token: 0.000015 } }
      workflow = klass.new(context: {})
      workflow.run!
      first = workflow.awaiting.token
      workflow.resume!(event: :batch_result, token: first, payload: { first => succeeded("line") })
      second = workflow.awaiting.token

      expect(calls).to eq([[:reserve, first], [:reconcile, first], [:reserve, second]])
    ensure
      Smith.config.pricing = nil
    end
  end

  describe "restoring" do
    it "refuses a pending batch whose progress is missing, malformed or past the step's rounds" do
      klass = drafting("SpecOptBatchRestoreWorkflow")
      klass.new(context: {}).run_persisted!("opt-restore", adapter:)
      state = JSON.parse(adapter.fetch("opt-restore"))
      pending = state["pending_batch"]
      restore = ->(changes) { klass.from_state(state.merge("pending_batch" => pending.merge(changes))) }

      expect(restore.call({}).awaiting.kind).to eq(:batch)
      loop_state = pending["progress"]
      [nil, "x", loop_state.merge("round" => 2), loop_state.merge("round" => -1), loop_state.merge("role" => "worker"),
       loop_state.merge("last_score" => "high"), loop_state.except("feedback"), loop_state.merge("extra" => 1),
       loop_state.merge("evaluations" => { "1" => [{ "round" => 0 }] }),
       loop_state.merge("evaluations" => { "x" => [] })].each do |progress|
        expect { restore.call("progress" => progress) }.to raise_error(Smith::SerializationError), progress.inspect
      end
      expect { klass.from_state(state.merge("pending_batch" => pending.except("progress"))) }
        .to raise_error(Smith::SerializationError)
    end

    it "refuses progress that is not the progress of the wait it was stored with" do
      klass = drafting("SpecOptBatchBoundWorkflow", max_rounds: 3)
      klass.new(context: {}).run_persisted!("opt-bound", adapter:)
      state = JSON.parse(adapter.fetch("opt-bound"))
      pending = state["pending_batch"]
      restore = ->(progress) { klass.from_state(state.merge("pending_batch" => pending.merge("progress" => progress))) }

      expect(restore.call(pending["progress"]).awaiting.kind).to eq(:batch)
      [pending["progress"].merge("round" => 2), pending["progress"].merge("role" => "evaluator")].each do |progress|
        expect { restore.call(progress) }.to raise_error(Smith::SerializationError, /its wait/), progress.inspect
      end
    end

    it "refuses progress on another kind of batch step" do
      klass = with_stubbed_class("SpecOptBatchPlainWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "write a line" }] }
        transition :draft, from: :idle, to: :done do
          execute :spec_opt_batch_writer, mode: :batch
          on_failure :fail
        end
      end
      klass.new(context: {}).run_persisted!("opt-plain", adapter:)
      state = JSON.parse(adapter.fetch("opt-plain"))
      progress = { "round" => 0, "role" => "generator", "candidate" => nil, "feedback" => nil, "last_score" => nil,
                   "evaluations" => {} }

      expect { klass.from_state(state.merge("pending_batch" => state["pending_batch"].merge("progress" => progress))) }
        .to raise_error(Smith::SerializationError)
    end
  end
end
