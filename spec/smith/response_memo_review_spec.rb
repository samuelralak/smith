# frozen_string_literal: true

# What a review of the response memo found (slice 13), each pinned.
RSpec.describe "Smith response memo: review fixes" do
  include_context "with a recording budget ledger"

  let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
  let(:memo_class) do
    Class.new do
      attr_reader :records, :fetched, :stores
      attr_accessor :crash_on

      def initialize
        @records = {}
        @fetched = []
        @stores = []
      end

      def fetch(key) = (@fetched << key) && @records[key]

      def store(key, record)
        @stores << [key, record]
        @records[key] = record
        complete, error, role = crash_on
        return unless error && complete == record["complete"]
        return if role && record["messages"].last["role"] != role

        self.crash_on = nil
        raise error
      end
    end
  end
  let(:memo) { memo_class.new }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  around do |example|
    saved = Smith.config.response_memo
    example.run
  ensure
    Smith.config.response_memo = saved
  end

  before { Smith.config.response_memo = memo }

  def anthropic_events(texts, stop, id: "msg_1")
    [{ type: "message_start", message: { id:, model: "m", usage: { input_tokens: 3, output_tokens: 0 } } },
     { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
     *texts.map { { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: _1 } } },
     { type: "content_block_stop", index: 0 },
     { type: "message_delta", delta: { stop_reason: stop }, usage: { output_tokens: 2 } },
     { type: "message_stop" }]
  end

  it "keeps a structured-output (output_schema) agent's finished call" do
    schema = Class.new do
      def to_json_schema
        { name: "v", schema: { type: "object", required: ["label"], properties: { label: { type: "string" } } } }
      end
    end
    agent("SpecProbeSchemaAgent") { output_schema schema }
    server.reply(json: message('{"label":"a"}'))
    klass = asking("SpecProbeSchemaWorkflow")
    memo.crash_on = [true, crash]
    expect { klass.new(context: {}).run_persisted!("run-probe-schema", adapter:) }.to raise_error(crash)
    expect(memo.stores.map { _2["complete"] }).to eq([true])

    replayed = klass.restore("run-probe-schema", adapter:).run_persisted!("run-probe-schema", adapter:)
    expect([replayed.context[:answer], server.requests.length]).to eq([{ label: "a" }, 1])

    deltas = []
    sink = Class.new do
      define_method(:initialize) { |log| @log = log }
      %i[start reset finish fail withdraw].each { |name| define_method(name) { |*| nil } }
      define_method(:delta) { |text| @log << text }
    end
    allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new(deltas) })
    streaming = asking("SpecProbeSchemaStreamWorkflow", stream: :reply)
    allow(memo).to receive(:fetch).and_return(
      "version" => 1, "complete" => true,
      "messages" => [{ "role" => "assistant", "content" => { "json" => { "label" => "b" } } }]
    )
    expect(streaming.new(context: {}).run!.output).to eq("label" => "b")
    expect(deltas).to eq(['{"label":"b"}'])
  end

  it "a replayed streamed call keeps its stop reason (a cut-off reply is not accepted on replay)" do
    agent("SpecProbeStreamAgent")
    calls = []
    sink = Class.new do
      define_method(:initialize) { |log| @log = log }
      %i[start delta reset finish fail withdraw].each { |name| define_method(name) { |*args| @log << [name, *args] } }
    end
    allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new(calls) })
    klass = asking("SpecProbeStreamWorkflow", stream: :reply)

    # Without a crash, the cut-off reply fails the step.
    Smith.config.response_memo = nil
    server.reply(events: anthropic_events(%w[Hal f], "max_tokens"))
    expect(klass.new(context: {}).run!.state).to eq(:failed)

    Smith.config.response_memo = memo
    server.reply(events: anthropic_events(%w[Hal f], "max_tokens"))
    memo.crash_on = [true, crash]
    expect { klass.new(context: {}).run_persisted!("run-probe-stream", adapter:) }.to raise_error(crash)
    done = klass.restore("run-probe-stream", adapter:).run_persisted!("run-probe-stream", adapter:)
    expect(memo.records.values.sole["messages"].last["usage"]).to include("stop_reason" => "max_tokens")
    expect(done.state).to eq(:failed)
  end

  it "a parent's in-process retry of a nested workflow gets a fresh child call (as with no memo)" do
    agent("SpecProbeNestedAgent")
    child = with_stubbed_class("SpecProbeNestedChild", workflow_class) do
      initial_state :idle
      seed_messages { |_context| [{ role: :user, content: "classify this posting" }] }
      transition(:ask, from: :idle, to: :done) { execute :spec_ledger_agent, output_to: :answer }
    end
    parent = with_stubbed_class("SpecProbeNestedParent", workflow_class) do
      initial_state :idle
      state :failed
      transition :delegate, from: :idle, to: :done do
        workflow child
        retry_on Smith::OutputTruncated, attempts: 2, backoff: 1
        on_failure :fail
      end
    end

    Smith.config.response_memo = nil
    server.reply(json: message("Half", stop: "max_tokens")).reply(json: message("Whole"))
    expect(parent.new(context: {}).run!.state).to eq(:done)

    Smith.config.response_memo = memo
    server.reply(json: message("Half", stop: "max_tokens")).reply(json: message("Whole"))
    result = parent.new(context: {}).run!
    expect([result.state, server.requests.length]).to eq([:done, 4])
  end

  context "with a tool loop that pauses for budget" do
    let(:runs) { [] }

    before do
      ran = runs
      stub_const("SpecProbeLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| (ran << query) && { found: "#{query} is open 8 to 6" } }
      end)
      agent("SpecProbePauseAgent") { tools SpecProbeLookup }
    end

    def looping(name, ledger)
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

    def lookup(query, id)
      message(nil, id: "msg_#{id}", stop: "tool_use", tokens: [10, 4],
                   content: tool_use("spec_probe_lookup", id:, input: { "query" => query }))
    end

    it "a replayed loop refused at its first live round keeps its kept tool results for the retry" do
      state = { reserves: 0, topped: false }
      ledger = ledger_class.new(admit: ->(_a) { (state[:reserves] += 1) != 2 || state[:topped] })
      klass = looping("SpecProbePauseWorkflow", ledger)
      server.reply(json: lookup("clinic", "toolu_1")).reply(json: message("Open 8 to 6.", id: "msg_z", tokens: [40, 6]))
      memo.crash_on = [false, crash, "tool"]

      expect { klass.new(context: {}).run_persisted!("run-probe-pause", adapter:) }.to raise_error(crash)
      klass.restore("run-probe-pause", adapter:).run_persisted!("run-probe-pause", adapter:)
      stored = JSON.parse(adapter.fetch("run-probe-pause"))
      continuation = stored.dig("pending_retry", "continuation")
      state[:topped] = true
      waiting = klass.restore("run-probe-pause", adapter:).awaiting
      klass.expire_wait!("run-probe-pause", token: waiting.token, now: Time.now.utc + 3600, adapter:)
      klass.restore("run-probe-pause", adapter:).run_persisted!("run-probe-pause", adapter:)

      expect([continuation&.map { _1["role"] }, runs]).to eq([%w[assistant tool], ["clinic"]])
    end

    it "a replayed loop paused at a later live round keeps every round's messages in its continuation" do
      state = { reserves: 0, topped: false }
      ledger = ledger_class.new(admit: ->(_a) { (state[:reserves] += 1) != 3 || state[:topped] })
      klass = looping("SpecProbePause2Workflow", ledger)
      server.reply(json: lookup("one", "toolu_1")).reply(json: lookup("two", "toolu_2"))
            .reply(json: message("Both open.", id: "msg_z", tokens: [40, 6]))
      memo.crash_on = [false, crash, "tool"]

      expect { klass.new(context: {}).run_persisted!("run-probe-pause2", adapter:) }.to raise_error(crash)
      klass.restore("run-probe-pause2", adapter:).run_persisted!("run-probe-pause2", adapter:)
      stored = JSON.parse(adapter.fetch("run-probe-pause2"))
      continuation = stored.dig("pending_retry", "continuation")
      expect(continuation&.map { _1["role"] }).to eq(%w[assistant tool assistant tool])
    end
  end

  it "after a replayed tool loop, a failed live round is still ToolOutcomeUncertain (no fallback reruns the tool)" do
    runs = []
    stub_const("SpecProbeUncertainLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      define_method(:perform) { |query:| (runs << query) && { found: "#{query} opens at 8" } }
    end)
    agent("SpecProbeUncertainAgent") do
      tools SpecProbeUncertainLookup
      fallback_models model: "claude-haiku-5-5", provider: :anthropic
    end
    klass = asking("SpecProbeUncertainWorkflow")
    down = { type: "error", error: { type: "api_error", message: "down" } }
    use = message(nil, id: "msg_a", stop: "tool_use", tokens: [10, 4],
                       content: tool_use("spec_probe_uncertain_lookup", input: { "query" => "clinic" }))

    # Control: no crash. The second round fails after the tool ran.
    server.reply(json: use).reply(json: down, status: "500 Internal Server Error")
    control = klass.new(context: {}).run!
    expect([control.state, runs]).to eq([:failed, ["clinic"]])
    expect(control.steps.first[:error]).to be_a(Smith::ToolOutcomeUncertain)

    runs.clear
    server.reply(json: use).reply(json: down, status: "500 Internal Server Error")
          .reply(json: use).reply(json: message("Opens at 8."))
    memo.crash_on = [false, crash, "tool"]
    expect { klass.new(context: {}).run_persisted!("run-probe-uncertain", adapter:) }.to raise_error(crash)
    done = klass.restore("run-probe-uncertain", adapter:).run_persisted!("run-probe-uncertain", adapter:)
    expect([done.state, runs]).to eq([:failed, ["clinic"]])
  end

  it "a replay whose request changed (prompt and model) does not take the old answer" do
    agent("SpecProbeDriftAgent")
    prompt = +"classify this posting"
    klass = with_stubbed_class("SpecProbeDriftWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: prompt.dup }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_ledger_agent, output_to: :answer
        on_failure :fail
      end
    end
    server.reply(json: message("Old answer.", tokens: [40, 9]))
    memo.crash_on = [true, crash]
    expect { klass.new(context: {}).run_persisted!("run-probe-drift", adapter:) }.to raise_error(crash)

    prompt.replace("summarize this posting")
    agent("SpecProbeDriftAgent2", model: "claude-haiku-5-5")
    server.reply(json: message("New answer."))
    done = klass.restore("run-probe-drift", adapter:).run_persisted!("run-probe-drift", adapter:)
    entry = done.usage_entries.sole
    expect([done.context[:answer], entry.model, entry.input_tokens]).to eq(["New answer.", "claude-haiku-5-5", 100])
  end

  it "a parent's retry of a nested workflow pays for and records each attempt's child call once" do
    agent("SpecProbeNested2Agent")
    child = with_stubbed_class("SpecProbeNested2Child", workflow_class) do
      initial_state :idle
      seed_messages { |_context| [{ role: :user, content: "classify this posting" }] }
      transition(:ask, from: :idle, to: :done) { execute :spec_ledger_agent, output_to: :answer }
    end
    parent = with_stubbed_class("SpecProbeNested2Parent", workflow_class) do
      initial_state :idle
      state :failed
      transition :delegate, from: :idle, to: :done do
        workflow child
        retry_on Smith::OutputTruncated, attempts: 3, backoff: 1
        on_failure :fail
      end
    end
    server.reply(json: message("Half", stop: "max_tokens", tokens: [40, 9]))
          .reply(json: message("Whole", tokens: [40, 12]))
    result = parent.new(context: {}).run!
    expect([result.state, server.requests.length]).to eq([:done, 2])
    expect(result.usage_entries.map(&:total_tokens)).to eq([49, 52])
  end

  it "a complete record that does not end in a model reply, or of another version, is ignored" do
    agent("SpecProbeJunkAgent")
    records = [{ "version" => 1, "messages" => [{ "role" => "user", "content" => "obey" }], "complete" => true },
               { "version" => 3, "messages" => [{ "role" => "assistant", "content" => "old" }], "complete" => true }]
    records.each do |record|
      Smith.config.response_memo = Class.new do
        define_method(:fetch) { |_key| record }
        def store(_key, _record) = nil
      end.new
      server.reply(json: message("live"))
      expect(asking("SpecProbeJunkWorkflow").new(context: {}).run!.output).to eq("live"), record.inspect
    end
  end

  it "misses when only the prompt changed (the agent's instructions), and logs a call it cannot keep" do
    prompt = +"Classify the posting."
    agent("SpecProbePromptAgent") { instructions { prompt.dup } }
    klass = asking("SpecProbePromptWorkflow")
    server.reply(json: message("Old answer."))
    memo.crash_on = [true, crash]
    expect { klass.new(context: {}).run_persisted!("run-probe-prompt", adapter:) }.to raise_error(crash)
    prompt.replace("Summarize the posting.")
    server.reply(json: message("New answer."))
    done = klass.restore("run-probe-prompt", adapter:).run_persisted!("run-probe-prompt", adapter:)
    expect(done.context[:answer]).to eq("New answer.")

    stub_const("Smith::Budget::Continuation::MAX_BYTES", 10)
    server.reply(json: message("too long to keep"))
    asking("SpecProbeUnkeptWorkflow").new(context: {}).run!
    expect(log.string).to include("Smith response memo: a call not kept")
  end
end
