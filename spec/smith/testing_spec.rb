# frozen_string_literal: true

require "smith/testing/minitest"
require "smith/testing/rspec"

# The testing kit (smith/testing): a host's workflows run in its tests
# without a provider.
RSpec.describe "Smith::Testing" do
  include_context "with a recording budget ledger"

  let(:testing) { Smith::Testing }
  let(:schema) do
    Class.new do
      def to_json_schema
        { name: "v", schema: { type: "object", required: ["label"], properties: { label: { type: "string" } } } }
      end
    end
  end

  # Drafts with the agent, waits for an approval (or lapses), then sends.
  def approving(name)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "draft a note" }] }
      transition :draft, from: :idle, to: :drafted do
        execute :spec_ledger_agent, output_to: :draft
        on_failure :fail
      end
      transition :approve, from: :drafted, to: :approved do
        await :approval, into: :approval, timeout: 3_600
        on_timeout :lapse
      end
      transition :lapse, from: :drafted, to: :lapsed
      transition(:send_note, from: :approved, to: :done) { compute { |_step| nil } }
    end
  end

  def context_of(run) = run.to_state[:context]

  describe "stub_agent" do
    it "answers an agent's calls without sending anything, with the stub's usage and stop reason" do
      agent("SpecTestingAgent")
      stub = testing.stub_agent(SpecTestingAgent, outputs: "A short note.",
                                                  usage: { input_tokens: 40, output_tokens: 8 })
      klass = asking("SpecTestingWorkflow")
      run = klass.new(context: {})

      expect(testing.run_until_waiting(run)).to be_nil
      expect([run.state, context_of(run)[:answer], server.requests.length]).to eq([:done, "A short note.", 0])
      expect(run.usage_entries.map { [_1.input_tokens, _1.output_tokens, _1.stop_reason, _1.provider_message_id] })
        .to eq([[40, 8, "end_turn", "msg_stub_1"]])
      expect(stub.calls.map { |messages| messages.map(&:content) }).to eq([["classify this posting"]])

      testing.stub_agent(SpecTestingAgent, outputs: "A short", stop_reason: "max_tokens")
      cut = klass.new(context: {}).run!
      expect([cut.state, cut.last_error.class, cut.usage_entries.map(&:stop_reason)])
        .to eq([:failed, Smith::OutputTruncated, ["max_tokens"]])
    end

    it "takes its outputs in turn, the last again, and parses a reply under a schema" do
      shape = schema
      agent("SpecTestingSchemaAgent") { output_schema shape }
      testing.stub_agent(:spec_ledger_agent, outputs: ['{"label":"first"}', { "label" => "second" }])
      klass = asking("SpecTestingSchemaWorkflow")

      answers = Array.new(3) { klass.new(context: {}).tap(&:run!) }.map { context_of(_1)[:answer] }
      expect(answers).to eq([{ label: "first" }, { label: "second" }, { label: "second" }])
      expect(server.requests).to be_empty
    end

    it "answers a call the agent's output checks refuse, then its repair, from its next output" do
      shape = schema
      agent("SpecTestingRepairAgent") { output_schema shape }
      stub = testing.stub_agent(SpecTestingRepairAgent, outputs: ["not json", '{"label":"fixed"}'])
      run = asking("SpecTestingRepairWorkflow").new(context: {})
      run.run!

      expect([run.state, context_of(run)[:answer], stub.calls.length]).to eq([:done, { label: "fixed" }, 2])
    end

    it "streams a streamed step's reply to its sink in pieces" do
      deltas = []
      sink = Class.new do
        define_method(:initialize) { |log| @log = log }
        %i[start reset finish fail withdraw].each { |name| define_method(name) { |*| nil } }
        define_method(:delta) { |text| @log << text }
      end
      allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new(deltas) })
      agent("SpecTestingStreamAgent")
      testing.stub_agent(SpecTestingStreamAgent, outputs: "Seven words of a streamed reply here.", stream: 10)
      run = asking("SpecTestingStreamWorkflow", stream: :reply).new(context: {})
      run.run!

      expect(deltas).to eq(["Seven word", "s of a str", "eamed repl", "y here."])
      expect(run).to have_recorded_usage(mode: :stream, input_tokens: 10, output_tokens: 5)
    end

    it "runs the agent's own tools for a tool request, then answers its next request" do
      runs = []
      stub_const("SpecTestingLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| (runs << query) && { found: "#{query} opens at 8" } }
      end)
      agent("SpecTestingToolAgent") { tools SpecTestingLookup }
      stub = testing.stub_agent(SpecTestingToolAgent, outputs: [testing.tool_call(SpecTestingLookup, query: "clinic"),
                                                                "It opens at 8."])
      run = asking("SpecTestingToolWorkflow").new(context: {})
      run.run!

      expect([run.state, context_of(run)[:answer], runs, server.requests])
        .to eq([:done, "It opens at 8.", ["clinic"], []])
      expect(stub.calls.last.map(&:role)).to eq(%i[user assistant tool])
      expect(stub.calls.last.last.content).to include("clinic opens at 8")
      expect(run.usage_entries.map(&:stop_reason)).to eq(%w[tool_use end_turn])

      testing.stub_agent(SpecTestingToolAgent, outputs: [testing.tool_call("spec_testing_lookups"), "No."])
      failed = asking("SpecTestingToolWorkflow").new(context: {}).run!
      expect([failed.state, failed.last_error.message, runs.length])
        .to match([:failed, /names spec_testing_lookups, a tool the agent does not have \(it has spec_testing_lookup\)/,
                   1])
    end

    it "holds its requests on the step's budget ledger, and its call is kept in the response memo" do
      memo = Class.new do
        attr_reader :records

        def initialize = @records = {}
        def fetch(key) = @records[key]
        def store(key, record) = @records[key] = record
      end.new
      allow(Smith.config).to receive(:response_memo).and_return(memo)
      agent("SpecTestingHeldAgent")
      testing.stub_agent(SpecTestingHeldAgent, outputs: "Held.", usage: { input_tokens: 40, output_tokens: 8 })
      held = ledger
      run = asking("SpecTestingHeldWorkflow") { |_context| held }.new(context: {})
      run.run!

      expect([run.state, held.kinds]).to eq([:done, %i[reserve reconcile]])
      expect(held.calls.last.last).to have_attributes(input_tokens: 40, output_tokens: 8)
      expect(memo.records.values.map { [_1["complete"], _1["messages"].last["content"]] }).to eq([[true, "Held."]])
    end

    it "pauses a tool loop its budget ledger refuses, and continues it from the tool results" do
      runs = []
      stub_const("SpecTestingPauseLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| (runs << query) && { found: "#{query} opens at 8" } }
      end)
      agent("SpecTestingPauseAgent") { tools SpecTestingPauseLookup }
      stub = testing.stub_agent(SpecTestingPauseAgent,
                                outputs: [testing.tool_call(SpecTestingPauseLookup, query: "clinic"), "Opens at 8."])
      topped = false
      reserves = 0
      held = ledger_class.new(admit: ->(_amount) { (reserves += 1) != 2 || topped })
      klass = with_stubbed_class("SpecTestingPauseWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget_ledger { |_scope| held }
        seed_messages { |_context| [{ role: :user, content: "find the hours" }] }
        transition :ask, from: :idle, to: :done do
          execute :spec_ledger_agent, output_to: :answer
          retry_on Smith::BudgetUnavailable, attempts: 3, backoff: 60, durable: true
          on_failure :fail
        end
      end
      run = klass.new(context: {})

      expect(testing.run_until_waiting(run, retries: false)).to have_attributes(kind: :retry)
      topped = true
      expect([testing.run_until_waiting(run), run.state, context_of(run)[:answer]]).to eq([nil, :done, "Opens at 8."])
      expect([runs, stub.calls.length]).to eq([["clinic"], 2])
    end

    it "is dropped by reset!, and a call then goes over the wire" do
      agent("SpecTestingResetAgent")
      testing.stub_agent(:spec_ledger_agent, outputs: "stubbed")
      testing.reset!
      server.reply(json: message("live"))
      run = asking("SpecTestingResetWorkflow").new(context: {})
      run.run!

      expect([context_of(run)[:answer], server.requests.length]).to eq(["live", 1])
    end

    it "refuses a stub it cannot use" do
      agent("SpecTestingRefusedAgent")
      [{ outputs: [] }, { outputs: [1] }, { outputs: [[]] }, { outputs: [["x"]] },
       { outputs: "x", usage: { tokens: 1 } },
       { outputs: "x", usage: { input_tokens: -1 } }, { outputs: "x", stop_reason: :end_turn },
       { outputs: "x", stream: 0 }].each do |options|
        expect { testing.stub_agent(SpecTestingRefusedAgent, **options) }.to raise_error(ArgumentError), options.inspect
      end
    end
  end

  describe "running" do
    before do
      agent("SpecTestingDraftAgent")
      testing.stub_agent(SpecTestingDraftAgent, outputs: "Dear team,")
    end

    it "runs until a wait, delivers its event and runs on" do
      run = approving("SpecTestingApproveWorkflow").new(context: {})

      expect(testing.run_until_waiting(run)).to have_attributes(kind: :await, event: :approval)
      expect(run).to be_waiting_for(:approval)
      expect(testing.resume_with(run, payload: { "approved" => true })).to eq(:resumed)
      expect([run.state, context_of(run)[:approval]]).to eq([:done, { approved: true }])
      expect(run).to have_transitioned_through(:draft, :approve, :send_note)
      expect(testing.transitions(run)).to eq(%i[draft approve send_note])
    end

    it "ends a wait as if its deadline had passed" do
      run = approving("SpecTestingLapseWorkflow").new(context: {})
      testing.run_until_waiting(run)

      expect(testing.expire(run)).to eq(:expired)
      expect(run.state).to eq(:lapsed)
      expect(run).to have_transitioned_through(:draft, :lapse)
      expect { testing.expire(run) }.to raise_error(ArgumentError, /not waiting/)
    end

    it "ends a durable retry's backoff at once, unless told not to" do
      stub_const("SpecTestingBusy", Class.new(StandardError))
      klass = with_stubbed_class("SpecTestingRetryWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :charge, from: :idle, to: :done do
          compute { |step| raise SpecTestingBusy if step.attempt == 1 }
          retry_on SpecTestingBusy, attempts: 2, backoff: 30, durable: true
          on_failure :fail
        end
      end

      expect(testing.run_until_waiting(klass.new(context: {}), retries: false)).to have_attributes(kind: :retry)
      run = klass.new(context: {})
      expect([testing.run_until_waiting(run), run.state]).to eq([nil, :done])
    end
  end

  describe "batch deliveries" do
    let(:queue) { batch_queue }

    before { Smith.config.batch_queue = queue }

    it "builds an agent step's delivery from its result" do
      agent("SpecTestingBatchAgent")
      stub = testing.stub_agent(SpecTestingBatchAgent, outputs: "stubbed")
      run = asking("SpecTestingBatchWorkflow", mode: :batch).new(context: {})

      expect(testing.run_until_waiting(run)).to have_attributes(kind: :batch)
      expect(run).to be_waiting_for(kind: :batch)
      result = testing.batch_result("From the batch.", usage: { input_tokens: 30, output_tokens: 6 })
      expect(testing.resume_with(run, payload: testing.batch_payload(run, result))).to eq(:resumed)
      expect([run.state, context_of(run)[:answer], stub.calls, server.requests])
        .to eq([:done, "From the batch.", [], []])
      expect(run).to have_recorded_usage(mode: :batch, input_tokens: 30, output_tokens: 6, count: 1)
    end

    it "builds a fan-out's delivery from its results by branch key, and a failed result" do
      %i[spec_detect spec_extract].each { agent("SpecTesting#{_1.to_s.split("_").last.capitalize}Agent", register: _1) }
      klass = with_stubbed_class("SpecTestingFanWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "read" }] }
        transition :read, from: :idle, to: :done do
          fan_out branches: { detect: :spec_detect, extract: :spec_extract }, mode: :batch, output_to: :read
          on_failure :fail
        end
      end
      run = klass.new(context: {})
      testing.run_until_waiting(run)
      payload = testing.batch_payload(run, detect: testing.batch_result("clean"),
                                           extract: testing.batch_result("fields"))

      expect(payload.keys).to eq(queue.items.map { _1[:custom_id] })
      expect(testing.resume_with(run, payload:)).to eq(:resumed)
      expect(context_of(run)[:read].map { [_1[:branch], _1[:output]] }).to eq([%w[detect clean], %w[extract fields]])
      expect(testing.batch_result(type: "expired")).to eq("type" => "expired")
    end
  end

  describe "the checks" do
    it "say what failed, as matcher failures" do
      agent("SpecTestingCheckAgent")
      testing.stub_agent(SpecTestingCheckAgent, outputs: "done")
      run = asking("SpecTestingCheckWorkflow").new(context: {})
      run.run!

      failure = lambda do |matcher|
        expect(matcher.matches?(run)).to be(false)
        matcher.failure_message
      end
      expect(failure.call(be_waiting_for(:approval))).to eq("expected the run to wait, but it is done and not waiting")
      expect(failure.call(have_transitioned_through(:ask, :ask))).to include("it went through [:ask]")
      expect(failure.call(have_recorded_usage(agent_name: SpecTestingCheckAgent, count: 2))).to include("found 1")
      expect(be_waiting_for(:approval).tap { _1.matches?(run) }.failure_message_when_negated)
        .to eq("expected the run not to wait for approval")
      expect { have_recorded_usage(tokens: 1).matches?(run) }.to raise_error(ArgumentError, /tokens/)
    end

    it "are Minitest assertions too, and the stubs go after each test" do
      host_test = Class.new do
        attr_reader :asserted

        def after_teardown = nil
        def assert(test, message = nil) = (@asserted ||= []) << [test, message]
      end
      host_test = Class.new(host_test) { include Smith::Testing::Assertions }.new
      agent("SpecTestingMinitestAgent")
      testing.stub_agent(SpecTestingMinitestAgent, outputs: "done")
      run = asking("SpecTestingMinitestWorkflow").new(context: {})
      run.run!

      host_test.assert_usage_recorded(run, agent_name: :spec_ledger_agent, output_tokens: 5)
      host_test.assert_transitioned_through(run, :ask)
      host_test.assert_waiting_for(run, kind: :batch)
      host_test.after_teardown
      expect(host_test.asserted.map(&:first)).to eq([true, true, false])
      expect(host_test.asserted.last.last).to include("not waiting")
      expect(testing.stub_for(SpecTestingMinitestAgent)).to be_nil
    end
  end
end
