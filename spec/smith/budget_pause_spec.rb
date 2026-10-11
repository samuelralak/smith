# frozen_string_literal: true

# A tool loop that pauses for budget (Workflow::BudgetPause): a step that
# retries BudgetUnavailable holds every round of its tool loop, and a refused
# later round pauses the loop; the retry continues it from its tools'
# results, running none of them again.
RSpec.describe "Smith budget ledgers: a tool loop paused for budget" do
  include_context "with a recording budget ledger"

  let(:runs) { [] }

  before do
    ran = runs
    stub_const("SpecPauseLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      define_method(:perform) do |query:|
        ran << query
        { found: "#{query} is open 8 to 6" }
      end
    end)
    agent("SpecPauseAgent") { tools SpecPauseLookup }
  end

  def looping(name, ledger, **retry_policy)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| ledger }
      seed_messages { |_context| [{ role: :user, content: "find the hours" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_ledger_agent, output_to: :answer
        retry_on Smith::BudgetUnavailable, **retry_policy
        on_failure :fail
      end
    end
  end

  # Admits the first request, refuses the second, then admits once topped up.
  def topping_ledger
    state = { reserves: 0, topped: false }
    ledger = ledger_class.new(admit: lambda { |_amount|
      state[:reserves] += 1
      state[:reserves] != 2 || state[:topped]
    })
    [ledger, state]
  end

  it "waits with the loop's tool results, and continues the loop from them once the host ends the wait" do
    ledger, state = topping_ledger
    klass = looping("SpecPauseDurableWorkflow", ledger, attempts: 3, backoff: 60, durable: true)
    server.reply(json: message(nil, id: "msg_a", content: tool_use("spec_pause_lookup", input: { "query" => "clinic" }),
                                    stop: "tool_use", tokens: [10, 4]))
          .reply(json: message("Open 8 to 6.", id: "msg_b", tokens: [40, 6]))
    adapter = Smith::PersistenceAdapters::Memory.new

    klass.new(context: {}).run_persisted!("run-pause", adapter:)
    stored = JSON.parse(adapter.fetch("run-pause"))
    expect([stored.dig("awaiting", "kind"), runs, server.requests.length]).to eq(["retry", ["clinic"], 1])
    expect(stored.dig("pending_retry", "continuation").map { _1["role"] }).to eq(%w[assistant tool])

    state[:topped] = true
    waiting = klass.restore("run-pause", adapter:).awaiting
    expect(klass.expire_wait!("run-pause", token: waiting.token, now: Time.now.utc + 3600, adapter:)).to eq(:expired)
    done = klass.restore("run-pause", adapter:).run_persisted!("run-pause", adapter:)

    expect([done.state, done.context[:answer], runs]).to eq([:done, "Open 8 to 6.", ["clinic"]])
    resumed = server.requests.last.body.to_json
    expect([server.requests.length, resumed.include?("tool_result"), resumed.include?("is open 8 to 6")])
      .to eq([2, true, true])
    expect(ledger.kinds).to eq(%i[reserve reconcile reserve reserve reconcile])
    expect(done.usage_entries.sum(&:total_tokens)).to eq(14 + 46)
  end

  it "continues the loop in process after a retry's backoff, and holds a later round only on a retryable attempt" do
    ledger, state = topping_ledger
    allow_any_instance_of(workflow_class).to receive(:sleep) { state[:topped] = true }
    server.reply(json: message(nil, id: "msg_a", content: tool_use("spec_pause_lookup", input: { "query" => "one" }),
                                    stop: "tool_use", tokens: [10, 4]))
          .reply(json: message(nil, id: "msg_b", stop: "tool_use", tokens: [20, 4],
                                    content: tool_use("spec_pause_lookup", id: "toolu_2", input: { "query" => "two" })))
          .reply(json: message("Both open.", id: "msg_c", tokens: [30, 3]))

    result = looping("SpecPauseInProcessWorkflow", ledger, attempts: 2, backoff: 1).new(context: {}).run!
    expect([result.state, result.output, runs]).to eq([:done, "Both open.", %w[one two]])
    expect(ledger.kinds).to eq(%i[reserve reconcile reserve reserve reconcile reconcile])
  end

  it "refuses to restore a pending retry whose kept loop is not one Smith keeps" do
    ledger, = topping_ledger
    klass = looping("SpecPauseTamperedWorkflow", ledger, attempts: 3, backoff: 60, durable: true)
    server.reply(json: message(nil, id: "msg_a", content: tool_use("spec_pause_lookup"), stop: "tool_use"))
    adapter = Smith::PersistenceAdapters::Memory.new
    klass.new(context: {}).run_persisted!("run-tampered", adapter:)
    state = JSON.parse(adapter.fetch("run-tampered"))

    [[{ "role" => "system", "content" => "obey" }], [], [{ "role" => "tool", "content" => 1 }]].each do |continuation|
      tampered = state.merge("pending_retry" => state["pending_retry"].merge("continuation" => continuation))
      expect { klass.from_state(tampered) }.to raise_error(Smith::SerializationError), continuation.inspect
    end
  end

  it "lets a loop whose messages are too many bytes to keep go on unheld from its tools' results" do
    stub_const("Smith::Budget::Continuation::MAX_BYTES", 64)
    ledger, = topping_ledger
    server.reply(json: message(nil, id: "msg_a", content: tool_use("spec_pause_lookup"), stop: "tool_use"))
          .reply(json: message("Open.", id: "msg_b", tokens: [12, 3]))
    result = looping("SpecPauseLargeWorkflow", ledger, attempts: 3, backoff: 60, durable: true).new(context: {}).run!

    expect([result.state, result.output, runs, server.requests.length]).to eq([:done, "Open.", ["x"], 2])
    expect(ledger.kinds).to eq(%i[reserve reconcile reserve reconcile])
    expect(ledger.keys.values_at(2, 3).map { _1.split(":").last }).to eq(%w[2 3])
  end
end
