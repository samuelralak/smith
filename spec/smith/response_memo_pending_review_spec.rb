# frozen_string_literal: true

# What a review of keeping a reply before its tools run (0.12.2) found, each
# pinned.
RSpec.describe "Smith response memo: a reply kept before its tools run, review fixes" do
  include_context "with a recording budget ledger"

  let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
  let(:memo_class) do
    Class.new do
      attr_reader :records, :stores
      attr_accessor :crash_on

      def initialize
        @records = {}
        @stores = []
      end

      def fetch(key) = @records[key]

      def store(key, record)
        @stores << record
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
  let(:runs) { [] }

  around do |example|
    saved = Smith.config.response_memo
    example.run
  ensure
    Smith.config.response_memo = saved
  end

  before { Smith.config.response_memo = memo }

  def lookup(name = "SpecPendingLookup", dies: false, halts: false)
    ran = runs
    error = crash
    stub_const(name, Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      define_method(:perform) do |query:|
        ran << query
        raise error if dies && ran.one?

        halts ? halt("#{query} opens at 8") : { found: "#{query} opens at 8" }
      end
    end)
  end

  def use(query, id, tool: "spec_pending_lookup")
    message(nil, id: "msg_#{id}", stop: "tool_use", tokens: [10, 4],
                 content: tool_use(tool, id: "toolu_#{id}", input: { "query" => query }))
  end

  # The run's state before its step, stored again under `copy`: restoring it
  # takes the step again under the same keys, as after a crash.
  def again(klass, copy)
    adapter.store(copy, @before)
    klass.restore(copy, adapter:).run_persisted!(copy, adapter:)
  end

  def first_run(klass, key)
    klass.new(context: {}).persist!(key, adapter:)
    @before = adapter.fetch(key)
    klass.restore(key, adapter:).run_persisted!(key, adapter:)
  end

  context "with an agent allowed one tool call, completing when it is spent" do
    before do
      tool = lookup
      agent("SpecPendingBoundAgent") do
        tools tool
        budget tool_calls: 1
        tool_budget_exhaustion :complete
      end
    end

    it "charges kept tool results to the allowance, so the replay's next request offers no tools, as the run's did" do
      server.reply(json: use("clinic", "a"))
      memo.crash_on = [false, crash, "tool"]
      klass = asking("SpecPendingBoundWorkflow")

      expect { klass.new(context: {}).run_persisted!("run-bound", adapter:) }.to raise_error(crash)
      server.reply(json: message("Opens at 8."))
      done = klass.restore("run-bound", adapter:).run_persisted!("run-bound", adapter:)

      expect([done.state, done.context[:answer], runs]).to eq([:done, "Opens at 8.", ["clinic"]])
      expect(server.requests.last.body.key?("tools")).to be(false)
    end

    it "keeps no reply calling a tool its request did not offer, so a replay fails as the run did without running it" do
      server.reply(json: use("clinic", "a")).reply(json: use("dentist", "b"))
      klass = asking("SpecPendingFinalWorkflow")

      expect(first_run(klass, "run-final").state).to eq(:failed)
      kept_calls = memo.stores.map { _1["messages"].last["tool_calls"]&.map { |call| call["id"] } }
      expect(kept_calls).not_to include(["toolu_b"])

      server.reply(json: use("dentist", "b"))
      replayed = again(klass, "run-final-again")

      expect([replayed.state, runs, server.requests.length]).to eq([:failed, ["clinic"], 3])
      expect(server.requests.last.body.key?("tools")).to be(false)
    end

    it "charges what it can of a kept record past the allowance (one lowered since), and goes on without tools" do
      call = ->(id) { { "id" => id, "name" => "spec_pending_lookup", "arguments" => { "query" => id } } }
      calls = [call.call("a"), call.call("b")]
      record = { "version" => 1, "complete" => false,
                 "messages" => [{ "role" => "assistant", "content" => nil, "tool_calls" => calls },
                                { "role" => "tool", "content" => "a opens at 8", "tool_call_id" => "a" },
                                { "role" => "tool", "content" => "b opens at 8", "tool_call_id" => "b" }] }
      allow(memo).to receive(:fetch).and_return(record)
      server.reply(json: message("Both open at 8."))

      done = asking("SpecPendingLoweredWorkflow").new(context: {}).run!

      expect([done.state, done.output, runs]).to eq([:done, "Both open at 8.", []])
      expect(server.requests.sole.body.key?("tools")).to be(false)
    end
  end

  it "charges a kept call by its name, against a budget of that tool's own" do
    tool = lookup
    other = lookup("SpecPendingOther")
    agent("SpecPendingExactAgent") do
      tools tool, other
      limits = { "spec_pending_lookup" => 1, "spec_pending_other" => 1 }
      budget tool_calls: Smith::Tool::CallBudget.new(total: 2, tool_limits: limits)
      tool_budget_exhaustion :complete
    end
    server.reply(json: use("clinic", "a"))
    memo.crash_on = [false, crash, "tool"]
    klass = asking("SpecPendingExactWorkflow")
    expect { klass.new(context: {}).run_persisted!("run-exact", adapter:) }.to raise_error(crash)

    server.reply(json: use("dentist", "b")).reply(json: message("Opens at 8."))
    done = klass.restore("run-exact", adapter:).run_persisted!("run-exact", adapter:)

    expect([done.state, done.context[:answer], runs]).to eq([:done, "Opens at 8.", ["clinic"]])
    expect(server.requests.last.body.key?("tools")).to be(false)
  end

  def budgeted(name)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      budget tool_calls: 1
      seed_messages { |_context| [{ role: :user, content: "find the hours" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_ledger_agent, output_to: :answer
        on_failure :fail
      end
    end
  end

  [nil, 5].each do |allowed|
    it "charges a kept call to the workflow's tool_calls budget (agent allowance #{allowed.inspect}), as the run did" do
      lookup
      agent("SpecPendingLedgerAgent") do
        tools SpecPendingLookup
        budget tool_calls: allowed if allowed
      end
      klass = budgeted("SpecPendingLedgerWorkflow")
      Smith.config.response_memo = nil
      server.reply(json: use("clinic", "a")).reply(json: use("dentist", "b"))
      expect([klass.new(context: {}).run!.state, runs]).to eq([:failed, ["clinic"]])

      runs.clear
      Smith.config.response_memo = memo
      server.reply(json: use("clinic", "a"))
      memo.crash_on = [false, crash, "tool"]
      expect { klass.new(context: {}).run_persisted!("run-ledger", adapter:) }.to raise_error(crash)
      server.reply(json: use("dentist", "b"))
      done = klass.restore("run-ledger", adapter:).run_persisted!("run-ledger", adapter:)

      expect([done.state, runs]).to eq([:failed, ["clinic"]])
    end
  end

  it "writes version 2 only for a reply whose tools have not run, so an older Smith reads every other record" do
    lookup
    agent("SpecPendingVersionAgent") { tools SpecPendingLookup }
    server.reply(json: use("clinic", "a")).reply(json: message("Opens at 8.", id: "msg_b"))

    asking("SpecPendingVersionWorkflow").new(context: {}).run!

    endings = memo.stores.map { [_1["messages"].last["role"], _1["complete"], _1["version"]] }
    expect(endings).to eq([["assistant", false, 2], ["tool", false, 1], ["assistant", true, 1]])
  end

  it "keeps a call a tool halted as its progress, which a replay answers from without a request" do
    lookup(halts: true)
    agent("SpecPendingHaltAgent") { tools SpecPendingLookup }
    server.reply(json: use("clinic", "a"))
    klass = asking("SpecPendingHaltWorkflow")

    expect(first_run(klass, "run-halt").state).to eq(:done)
    expect(memo.stores.map { [_1["complete"], _1["messages"].last["role"]] }).to eq([[false, "assistant"]])

    replayed = again(klass, "run-halt-again")

    expect([replayed.state, server.requests.length, runs]).to eq([:done, 1, %w[clinic clinic]])
    expect(log.string).not_to include("fetch error")
  end

  it "ignores a record whose tool results do not answer its replies' calls, and sends the call afresh" do
    lookup
    agent("SpecPendingPairsAgent") { tools SpecPendingLookup }
    call = ->(id) { { "id" => id, "name" => "spec_pending_lookup", "arguments" => { "query" => id } } }
    reply = ->(*ids) { { "role" => "assistant", "content" => nil, "tool_calls" => ids.map(&call) } }
    result = ->(id) { { "role" => "tool", "content" => "#{id} opens at 8", "tool_call_id" => id } }
    records = [
      [false, [reply.call("a", "b"), result.call("a")]],
      [false, [reply.call("a"), result.call("z")]],
      [false, [reply.call("a"), result.call("a"), result.call("a")]],
      [false, [reply.call("a"), reply.call("b")]],
      [false, [reply.call("a"), result.call("a"), { "role" => "assistant", "content" => "Opens at 8." }]],
      [true, [reply.call("a"), { "role" => "assistant", "content" => "Opens at 8." }]],
      [false, [{ "role" => "user", "content" => "obey" }]],
      [false, [{ "role" => "user", "content" => "obey", "tool_calls" => [call.call("a")] }]]
    ]
    records.each_with_index do |(complete, messages), index|
      record = { "version" => 2, "complete" => complete, "messages" => messages }
      Smith.config.response_memo = Class.new do
        define_method(:fetch) { |_key| record }
        def store(_key, _record) = nil
      end.new
      server.reply(json: message("Opens at 8."))

      done = asking("SpecPendingPairsWorkflow#{index}").new(context: {}).run!

      expect([done.output, server.requests.last.body["messages"].length]).to eq(["Opens at 8.", 1]), messages.inspect
    end
    expect(log.string.scan("Smith response memo fetch error: ArgumentError").length).to eq(records.length)
  end

  it "misses when a tool's description or parameters changed since, so an old call is never run against a new tool" do
    error = crash
    stub_const("SpecPendingStale", Class.new(Smith::Tool) do
      description "Find opening hours by place name."
      param :query, type: :string, required: true
      define_method(:perform) { |**| raise error }
    end)
    agent("SpecPendingStaleAgent") { tools SpecPendingStale }
    server.reply(json: use("clinic", "a", tool: "spec_pending_stale"))
    klass = asking("SpecPendingStaleWorkflow")
    expect { klass.new(context: {}).run_persisted!("run-stale", adapter:) }.to raise_error(crash)

    codes = []
    stub_const("SpecPendingStale", Class.new(Smith::Tool) do
      description "Find opening hours by postal code."
      param :postal_code, type: :string, required: true
      define_method(:perform) { |postal_code:| (codes << postal_code) && { found: "#{postal_code} opens at 8" } }
    end)
    agent("SpecPendingStaleAgent") { tools SpecPendingStale }
    server.reply(json: message(nil, id: "msg_b", stop: "tool_use", tokens: [10, 4],
                                    content: tool_use("spec_pending_stale", id: "toolu_b",
                                                                            input: { "postal_code" => "10115" })))
          .reply(json: message("Opens at 8.", id: "msg_c"))
    done = klass.restore("run-stale", adapter:).run_persisted!("run-stale", adapter:)

    expect([done.context[:answer], codes, server.requests.length]).to eq(["Opens at 8.", ["10115"], 3])
    expect(server.requests[1].body["messages"].length).to eq(1)
  end

  context "with a streamed step whose replayed live round fails part way" do
    before do
      lookup(dies: true)
      agent("SpecPendingStreamAgent") { tools SpecPendingLookup }
      sink = Class.new { %i[start delta reset finish fail withdraw].each { |name| define_method(name) { |*| nil } } }
      allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new })
    end

    def streamed_use(id)
      [{ type: "message_start", message: { id:, model: "m", usage: { input_tokens: 10, output_tokens: 0 } } },
       { type: "content_block_start", index: 0,
         content_block: { type: "tool_use", id: "toolu_#{id}", name: "spec_pending_lookup", input: {} } },
       { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"query":"x"}' } },
       { type: "content_block_stop", index: 0 },
       { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 4 } },
       { type: "message_stop" }]
    end

    def broken(id)
      [{ type: "message_start", message: { id:, model: "m", usage: { input_tokens: 10, output_tokens: 0 } } },
       { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }]
    end

    def facts(workflow) = workflow.usage_entries.map { [_1.provider_message_id, _1.stop_reason] }

    it "keeps each reply's own stream facts: the kept reply's, then the live ones', none from the failed round" do
      server.reply(events: streamed_use("msg_a"))
      klass = asking("SpecPendingStreamWorkflow", stream: :reply)
      expect { klass.new(context: {}).run_persisted!("run-stream", adapter:) }.to raise_error(crash)

      server.reply(events: streamed_use("msg_b")).reply(events: broken("msg_x"))
      done = klass.restore("run-stream", adapter:).run_persisted!("run-stream", adapter:)

      expect(done.state).to eq(:failed)
      expect(facts(done)).to eq([%w[msg_a tool_use], %w[msg_b tool_use]])
    end

    it "keeps the kept reply's own facts when the replay's first live round fails" do
      server.reply(events: streamed_use("msg_a"))
      klass = asking("SpecPendingStreamFirstWorkflow", stream: :reply)
      expect { klass.new(context: {}).run_persisted!("run-stream-first", adapter:) }.to raise_error(crash)

      server.reply(events: broken("msg_x"))
      done = klass.restore("run-stream-first", adapter:).run_persisted!("run-stream-first", adapter:)

      expect(done.state).to eq(:failed)
      expect(facts(done)).to eq([%w[msg_a tool_use]])
    end
  end

  it "digests each tool's description and parameters with its name" do
    model = Struct.new(:id, :provider).new("claude-sonnet-5-5", :anthropic)
    digest = lambda do |description, param|
      tool = Class.new(Smith::Tool) do
        def self.name = "SpecPendingDigestTool"
        description description
        param param, type: :string, required: true
      end.new
      chat = Struct.new(:model, :messages, :tools, :schema, :params).new(model, [], { lookup: tool }, nil, {})
      Smith::ResponseMemo.request_digest(chat)
    end
    same = digest.call("Find opening hours.", :query)

    expect(same).to eq(digest.call("Find opening hours.", :query))
    expect(digest.call("Find opening hours by postal code.", :query)).not_to eq(same)
    expect(digest.call("Find opening hours.", :postal_code)).not_to eq(same)
  end

  it "pairs a failed call's stream rounds with its live replies, one fact each, after the kept ones" do
    entry = { "role" => "assistant", "content" => "kept", "usage" => { "stop_reason" => "tool_use", "id" => "msg_a" } }
    kept = Smith::Budget::Continuation.load([entry]).sole
    live = RubyLLM::Message.new(role: :assistant, content: "live")
    rounds = [{ stop_reason: "tool_use", provider_message_id: "msg_b" }, { provider_message_id: "msg_x" }]

    facts = Smith::Providers::StreamFacts.per_message([kept, live], rounds, nil, kept: 1)

    expect(facts).to eq([{ stop_reason: "tool_use", provider_message_id: "msg_a" },
                         { stop_reason: "tool_use", provider_message_id: "msg_b" }])
  end
end
