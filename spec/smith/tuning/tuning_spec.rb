# frozen_string_literal: true

require "smith/tuning"

# Smith::Tuning.record and .cancel (slice 5a design, section 2): a tuning
# run's record read back from the store, and its cancel flag, under the
# configured default scope and store unless a call names its own.
RSpec.describe Smith::Tuning do
  let(:store) { Smith::Evals::Stores::Memory.new(clock: -> { EvalRecords::CLOCK_AT }) }
  let(:scope) { TuningRecords.scope }
  let(:run_id) { TuningRecords.tuning_run_id }

  def stored!
    store.create_tuning(scope:, header: TuningRecords.header)
    lease = store.acquire_lease(scope:, tuning_run_id: run_id)
    TuningRecords.lines.each { store.append_tuning_line(scope:, tuning_run_id: run_id, line: _1, lease:) }
    summarized!(lease)
  end

  def summarized!(lease)
    store.write_tuning_summary(scope:, tuning_run_id: run_id, summary: TuningRecords.summary, lease:)
    lease.release
  end

  it "reads a tuning run's record: header, lines in order, summary and candidates" do
    stored!
    record = described_class.record(run_id, scope:, store:)

    expect(record.tuning_run_id).to eq(run_id)
    expect(record.lines.map { _1.values_at("type", "iteration") })
      .to eq([["iteration", 0], ["reflection", 1], ["iteration", 1]])
    expect(record.summary).to eq(TuningRecords.summary)
    expect(record.candidates.map { [_1.index, _1.parent, _1.mean] }).to eq([[0, nil, 0.0], [1, 0, 0.25]])
    expect(record.reflections.first.dig("output", "instruction")).to eq(record.candidates.last.texts.values.first)
  end

  it "gives nil for a run the store does not hold in that scope" do
    stored!

    expect(described_class.record(run_id, scope: { tenant: "ten_0200" }, store:)).to be_nil
  end

  it "sets the cancel flag, the first request standing" do
    stored!
    actor = Smith::Evals::Actor.person("usr_51a8")

    expect(described_class.cancel(run_id, scope:, actor:, reason: "wrong split", store:)).to eq(:requested)
    expect(described_class.cancel(run_id, scope:, actor:, reason: nil, store:)).to eq(:exists)
    expect(store.cancel_request(scope:, tuning_run_id: run_id)).to include("reason" => "wrong split")
  end

  it "uses the configured scope and store when a call names none" do
    config = Smith::Evals::Configuration.new
    config.store = store
    config.default_scope = scope
    allow(Smith::Evals).to receive(:config).and_return(config)
    stored!

    expect(described_class.record(run_id)&.tuning_run_id).to eq(run_id)
  end

  it "refuses a store that keeps no tuning runs" do
    methods = Smith::Evals::Store::METHODS
    eval_only = Class.new { methods.each { |name| define_method(name) { |**| nil } } }.new

    expect { described_class.record(run_id, scope:, store: eval_only) }.to raise_error(ArgumentError, /tuning/)
  end
end
