# frozen_string_literal: true

require "smith/testing"

# Smith.config.persistence_max_bytes: a stored workflow state's bound. A
# step whose result would not fit fails before the result is kept; any
# other state past it is refused before anything is written.
RSpec.describe "Smith.config.persistence_max_bytes" do
  include_context "with a recording budget ledger"

  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:testing) { Smith::Testing }

  around do |example|
    saved = Smith.config.persistence_max_bytes
    example.run
  ensure
    Smith.config.persistence_max_bytes = saved
    Smith::Testing.reset!
  end

  def writing(name, bytes)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      transition :write, from: :idle, to: :done do
        compute { |step| step.write_context(:notes, "n" * bytes) }
      end
    end
  end

  def drafting(name, mode: :lax)
    with_stubbed_class(name, workflow_class) do
      idempotency_mode mode
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "draft" }] }
      transition :draft, from: :idle, to: :done do
        execute :spec_ledger_agent, output_to: :draft
        on_failure :fail
      end
    end
  end

  it "is nil or a positive Integer" do
    [0, -1, "1024", 1.5].each do |value|
      expect { Smith.config.persistence_max_bytes = value }.to raise_error(ArgumentError, /persistence_max_bytes/)
    end
    expect { Smith.config.persistence_max_bytes = 2048 }.not_to raise_error
    expect { Smith.config.persistence_max_bytes = nil }.not_to raise_error
  end

  it "refuses a state past it before writing, and the stored state stays as it was" do
    Smith.config.persistence_max_bytes = 4096
    klass = writing("SpecMaxBytesWorkflow", 8192)
    run = klass.new(context: {})

    expect { run.run_persisted!("run-big", adapter:) }.to raise_error(Smith::PersistedStateTooLarge) { |error|
      expect([error.key, error.limit, error.bytes > 8192]).to eq(["run-big", 4096, true])
    }
    stored = klass.restore("run-big", adapter:)
    expect([stored.state, stored.to_state[:context]]).to eq([:idle, {}])

    Smith.config.persistence_max_bytes = 64 * 1024
    expect(klass.restore("run-big", adapter:).run_persisted!("run-big", adapter:).state).to eq(:done)
  end

  it "fails a stored run's step whose result would not fit, keeping its usage, and the run stays storable" do
    Smith.config.persistence_max_bytes = 6_000
    agent("SpecMaxBytesAgent")
    testing.stub_agent(SpecMaxBytesAgent, outputs: "x" * 4_000, usage: { input_tokens: 30, output_tokens: 900 })

    %i[lax strict].each do |mode|
      klass = drafting("SpecMaxBytes#{mode.capitalize}Workflow", mode:)
      key = "run-step-#{mode}"
      run = klass.new(context: {})
      run.run_persisted!(key, adapter:)
      stored = klass.restore(key, adapter:)

      expect([stored.state, stored.to_state[:context][:draft]]).to eq([:failed, nil]), mode.to_s
      expect(stored.usage_entries.map { [_1.input_tokens, _1.output_tokens] }).to eq([[30, 900]])
      expect(run.run_persisted!(key, adapter:).last_error).to be_a(Smith::PersistedStateTooLarge)
    end
    expect(server.requests).to be_empty
  end

  it "counts a step's output as the state keeps it, twice" do
    agent("SpecMaxBytesTwiceAgent")
    testing.stub_agent(SpecMaxBytesTwiceAgent, outputs: "x" * 3_000)
    klass = drafting("SpecMaxBytesTwiceWorkflow")
    Smith.config.persistence_max_bytes = JSON.generate(klass.new(context: {}).to_state).bytesize + 5_500
    run = klass.new(context: {})
    run.run_persisted!("run-twice", adapter:)

    expect(klass.restore("run-twice", adapter:).state).to eq(:failed)
  end

  describe "a split step" do
    let(:digest) { Digest::SHA256.hexdigest("spec-max-bytes-split-v1") }

    def splitting(name, digest: nil)
      with_stubbed_class(name, workflow_class) do
        definition_digest digest if digest
        idempotency_mode :strict
        initial_state :idle
        state :failed
        transition(:finish, from: :idle, to: :done) { compute { |step| step.write_context(:done, true) } }
      end
    end

    it "refuses a preparation past it without counting a write as begun, so it can be prepared again" do
      Smith.config.persistence_max_bytes = 600
      run = splitting("SpecMaxBytesSplitWorkflow").new(context: { notes: "n" * 2_000 })

      expect { run.prepare_persisted_step!("run-split", adapter:) }.to raise_error(Smith::PersistedStateTooLarge)
      expect(adapter.fetch("run-split")).to be_nil
      Smith.config.persistence_max_bytes = nil
      run.prepare_persisted_step!("run-split", adapter:)
      run.execute_prepared_step!
      expect(run.state).to eq(:done)
    end

    it "leaves a refused checkpoint to be made again" do
      klass = splitting("SpecMaxBytesCheckpointWorkflow")
      run = klass.new(context: {})
      run.prepare_persisted_step!("run-checkpoint", adapter:)
      run.execute_prepared_step!
      Smith.config.persistence_max_bytes = 100

      expect { run.persist!("run-checkpoint", adapter:) }.to raise_error(Smith::PersistedStateTooLarge)
      Smith.config.persistence_max_bytes = nil
      run.persist!("run-checkpoint", adapter:)
      expect(klass.restore("run-checkpoint", adapter:).state).to eq(:done)
    end

    it "refuses a dispatch claim whose exact write would pass it, writing nothing" do
      run = splitting("SpecMaxBytesDispatchWorkflow", digest:).new(context: {})
      run.prepare_persisted_step!("run-dispatch", adapter:)
      prepared = adapter.fetch("run-dispatch")
      Smith.config.persistence_max_bytes = prepared.bytesize + 10

      expect { run.claim_prepared_step_dispatch! }.to raise_error(Smith::PersistedStateTooLarge)
      expect(adapter.fetch("run-dispatch")).to eq(prepared)
    end
  end

  it "keeps a step whose result fits, and checks nothing for a run never stored" do
    Smith.config.persistence_max_bytes = 6_000
    agent("SpecMaxBytesFitAgent")
    testing.stub_agent(SpecMaxBytesFitAgent, outputs: "x" * 1_000)
    stored = drafting("SpecMaxBytesFitWorkflow").new(context: {})
    stored.run_persisted!("run-fit", adapter:)

    testing.stub_agent(SpecMaxBytesFitAgent, outputs: "x" * 8_000)
    unstored = drafting("SpecMaxBytesFitWorkflow").new(context: {})
    unstored.run!
    expect([stored.state, unstored.state, unstored.to_state[:context][:draft].length]).to eq([:done, :done, 8_000])
  end

  it "does not pause a tool loop into a state it could not store; the loop goes on unheld" do
    stub_const("SpecMaxBytesLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      define_method(:perform) { |query:| { found: "#{query} #{"opens at 8 " * 300}" } }
    end)
    agent("SpecMaxBytesLoopAgent") { tools SpecMaxBytesLookup }
    loop_outputs = [testing.tool_call(SpecMaxBytesLookup, query: "clinic"), "At 8."]
    testing.stub_agent(SpecMaxBytesLoopAgent, outputs: loop_outputs)
    reserves = 0
    held = ledger_class.new(admit: ->(_amount) { (reserves += 1) != 2 })
    klass = with_stubbed_class("SpecMaxBytesPauseWorkflow", workflow_class) do
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

    Smith.config.persistence_max_bytes = 64 * 1024
    paused = klass.new(context: {})
    paused.run_persisted!("run-pause", adapter:)
    reserves = 0
    stub = testing.stub_agent(SpecMaxBytesLoopAgent, outputs: loop_outputs)
    Smith.config.persistence_max_bytes = 6_000
    went_on = klass.new(context: {})
    went_on.run_persisted!("run-on", adapter:)

    expect(paused.awaiting&.kind).to eq(:retry)
    expect([went_on.state, went_on.to_state[:context][:answer], stub.calls.length]).to eq([:done, "At 8.", 2])
    expect(held.kinds.last(4)).to eq(%i[reserve reconcile reserve reconcile])
  end
end
