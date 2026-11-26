# frozen_string_literal: true

require "json"

# The eval store's tuning methods (slice 5a design, section 3), one example
# group both stores pass, beside "an eval store": a tuning run's header
# written once, its lines appended (a line known by its type and
# iteration), its summary replaced by revision, its lease and cancel flag
# taken by its tuning run id, under the same scope rules. The including
# group defines `store` (empty, its clock at EvalRecords::CLOCK_AT) and
# `other_store` (another empty store).
RSpec.shared_examples "a tuning store" do
  let(:scope) { TuningRecords.scope }
  let(:run_id) { TuningRecords.tuning_run_id }
  let(:actor) { Smith::Evals::Actor.person("usr_51a8") }

  def valid!(record, schema)
    %i[open strict].each do |mode|
      expect(EvalsSchema.errors(record, schema:, strict: mode == :strict)).to eq([]), "#{schema} (#{mode})"
    end
  end

  def json(value) = EvalRecords.json(value)

  def created!(header = TuningRecords.header, scope: header.fetch("scope"))
    expect(store.create_tuning(scope:, header:)).to eq(:created)
    header
  end

  def leased(tuning_run_id = run_id, scope: self.scope) = store.acquire_lease(scope:, tuning_run_id:)

  def append(lease, line, tuning_run_id: line.fetch("tuning_run_id"))
    store.append_tuning_line(scope:, tuning_run_id:, line:, lease:)
  end

  def tuning_lines(tuning_run_id = run_id, scope: self.scope) = store.each_tuning_line(scope:, tuning_run_id:).to_a

  def summarize(lease, summary) = store.write_tuning_summary(scope:, tuning_run_id: run_id, summary:, lease:)

  it "creates a header once and reads every record back byte for byte, each valid against its schema" do
    header = created!
    expect(store.create_tuning(scope:, header: header.merge("idempotency_key" => "other"))).to eq(:exists)
    lease = leased
    TuningRecords.lines.each { expect(append(lease, _1)).to eq(:appended) }
    expect(summarize(lease, TuningRecords.summary)).to eq(:written)

    read = [store.read_tuning_header(scope:, tuning_run_id: run_id), *tuning_lines,
            store.read_tuning_summary(scope:, tuning_run_id: run_id)]
    expect(json(read.first)).to eq(json(TuningRecords.header))
    expect(read[1..-2].map { json(_1) }).to eq(TuningRecords.text("lines.jsonl").lines(chomp: true))
    expect(json(read.last)).to eq(json(TuningRecords.summary))
    expect(read).to all(be_frozen)
    valid!(read.first, "tuning-header")
    read[1..-2].each { valid!(_1, "tuning-line") }
    valid!(read.last, "tuning-summary")
  end

  it "knows a line by its type and iteration: the same line again is :exists, another is refused" do
    created!
    lease = leased
    seed, reflection, iteration = TuningRecords.lines

    expect([append(lease, seed), append(lease, reflection), append(lease, iteration)]).to eq(%i[appended] * 3)
    expect(append(lease, JSON.parse(json(iteration)).to_a.reverse.to_h)).to eq(:exists)
    expect { append(lease, iteration.merge("ended_as" => "rejected")) }.to raise_error(ArgumentError, /different line/)
    expect { append(lease, reflection.merge("failure" => { "kind" => "transport" })) }
      .to raise_error(ArgumentError, /different line/)
    expect(tuning_lines.map { _1.values_at("type", "iteration") }).to eq([["iteration", 0], ["reflection", 1],
                                                                          ["iteration", 1]])
  end

  # A resumed loop takes a new lease and may write a line again: the store
  # knows the lines already there by their type and iteration.
  it "knows its lines again under a new lease, as a resumed run would" do
    created!
    lease = leased
    TuningRecords.lines.each { append(lease, _1) }
    lease.release
    lease = leased
    seed, reflection, = TuningRecords.lines

    expect([append(lease, seed), append(lease, reflection)]).to eq(%i[exists exists])
    expect { append(lease, reflection.merge("failure" => { "kind" => "transport" })) }
      .to raise_error(ArgumentError, /different line/)
    expect(tuning_lines.size).to eq(3)
  end

  it "replaces the summary only by a higher revision" do
    created!
    lease = leased
    summarize(lease, TuningRecords.summary)

    expect(summarize(lease, TuningRecords.summary)).to eq(:exists)
    expect { summarize(lease, TuningRecords.summary_for(run_id, status: "finished")) }
      .to raise_error(ArgumentError, /revision 1/)
    expect(summarize(lease, TuningRecords.summary_for(run_id, revision: 2, status: "finished"))).to eq(:written)
    expect(store.read_tuning_summary(scope:, tuning_run_id: run_id)["status"]).to eq("finished")
  end

  it "refuses records it cannot file: another scope, run or format, a bad id, type or iteration" do
    header = TuningRecords.header
    [header.merge("scope" => { "tenant" => "ten_0200" }), header.merge("tuning_run_id" => "tu_short"),
     header.merge("format" => "smith.evals.record_header"), header.merge("created_at" => "today"),
     header.except("tuning_run_id")].each do |bad|
      expect { store.create_tuning(scope:, header: bad) }.to raise_error(ArgumentError), bad.keys.inspect
    end
    created!
    lease = leased
    line = TuningRecords.lines.first
    [line.merge("tuning_run_id" => TuningRecords.run_id(9)), line.merge("format" => "smith.evals.trial"),
     line.merge("type" => "other"), line.merge("iteration" => -1), line.merge("iteration" => "0"),
     line.except("type")].each do |bad|
      expect { append(lease, bad, tuning_run_id: run_id) }.to raise_error(ArgumentError), bad.inspect[0, 80]
    end
    [TuningRecords.summary.merge("status" => "succeeded"), TuningRecords.summary.merge("summary_revision" => 0),
     TuningRecords.summary.merge("scope" => { "tenant" => "ten_0200" })].each do |bad|
      expect { summarize(lease, bad) }.to raise_error(ArgumentError)
    end
    expect([tuning_lines, store.read_tuning_summary(scope:, tuning_run_id: run_id)]).to eq([[], nil])
  end

  it "takes the lease by the tuning run id: RunBusy while held, none for no record, writes only under it" do
    expect { leased }.to raise_error(ArgumentError, /no tuning run #{run_id}/)
    created!
    lease = leased

    expect { leased }.to raise_error(Smith::Evals::RunBusy, /tuning run #{run_id}/)
    expect(lease.tuning_run_id).to eq(run_id)
    line = TuningRecords.lines.first
    store.create_record(scope: EvalRecords.scope, header: EvalRecords.header)
    eval_lease = store.acquire_lease(scope: EvalRecords.scope, eval_run_id: EvalRecords.eval_run_id)
    [nil, eval_lease, Object.new, lease.tap(&:release)].each do |other|
      expect { append(other, line) }.to raise_error(ArgumentError, /lease/)
    end
    expect(append(leased, line)).to eq(:appended)
  end

  it "takes a cancel request by the tuning run id; the first stands, and it needs no lease" do
    created!

    expect(store.request_cancel(scope:, tuning_run_id: run_id, actor:, reason: "wrong split")).to eq(:requested)
    expect(store.request_cancel(scope:, tuning_run_id: run_id, actor:, reason: nil)).to eq(:exists)
    expect(store.cancel_request(scope:, tuning_run_id: run_id))
      .to eq("actor" => actor.to_h, "reason" => "wrong split", "at" => "2026-11-22T08:01:02.500Z")
    expect { store.request_cancel(scope:, tuning_run_id: TuningRecords.run_id(9), actor:, reason: nil) }
      .to raise_error(ArgumentError, /no tuning run/)
  end

  it "names a run by exactly one id of its kind, so an eval run and a tuning run never stand in for each other" do
    created!
    store.create_record(scope: EvalRecords.scope, header: EvalRecords.header)
    eval_id = EvalRecords.eval_run_id

    expect { store.acquire_lease(scope:, eval_run_id: eval_id, tuning_run_id: run_id) }
      .to raise_error(ArgumentError, /one of/)
    expect { store.acquire_lease(scope:) }.to raise_error(ArgumentError, /one of/)
    expect { store.cancel_request(scope:, tuning_run_id: eval_id) }.to raise_error(ArgumentError, /tuning run id/)
    expect { store.cancel_request(scope:, eval_run_id: run_id) }.to raise_error(ArgumentError, /eval run id/)
    expect { store.read_tuning_header(scope:, tuning_run_id: eval_id) }.to raise_error(ArgumentError)
    expect { store.read_header(scope:, eval_run_id: run_id) }.to raise_error(ArgumentError)
    ["tu_../../x", "../#{run_id}", run_id.upcase, "#{run_id}0", nil].each do |id|
      expect { store.read_tuning_header(scope:, tuning_run_id: id) }.to raise_error(ArgumentError), id.inspect
      expect { store.each_tuning_line(scope:, tuning_run_id: id).to_a }.to raise_error(ArgumentError), id.inspect
    end
    store.create_tuning(scope: EvalRecords.scope, header: TuningRecords.header_for(run_id, scope: EvalRecords.scope))
    expect(store.list_records(scope: EvalRecords.scope)["records"].map { _1["eval_run_id"] }).to eq([eval_id])
  end

  it "never shows one scope's tuning runs to another, nor another store's" do
    created!
    other_scope = { "tenant" => "ten_0200" }

    expect(store.read_tuning_header(scope: other_scope, tuning_run_id: run_id)).to be_nil
    expect(store.each_tuning_line(scope: other_scope, tuning_run_id: run_id).to_a).to eq([])
    expect(store.cancel_request(scope:, tuning_run_id: run_id)).to be_nil
    expect(other_store.read_tuning_header(scope:, tuning_run_id: run_id)).to be_nil
    expect(created!(TuningRecords.header_for(run_id, scope: other_scope))["scope"]).to eq(other_scope)
  end
end
