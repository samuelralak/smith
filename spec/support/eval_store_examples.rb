# frozen_string_literal: true

require "json"

# The eval store interface (slice-1a design, 9.1), one example group that
# every store passes: the memory store and the file store include it. The
# including group defines `store` (empty, its clock fixed at
# EvalRecords::CLOCK_AT), `other_store` (another empty store) and
# `store_with(clock:)` (a new empty store with that clock). Records come
# from EvalRecords, the contract examples, so each one read back is checked
# against its schema. A lease freed when its process dies (kill -9), or kept
# from a forked child, is the file store's own example (file_spec.rb): a
# memory store lives in one process, so its leases end with it by definition.
RSpec.shared_examples "an eval store" do
  let(:scope) { EvalRecords.scope }
  let(:run_id) { EvalRecords.eval_run_id }
  let(:other_scope) { { "tenant" => "ten_0200" } }

  def valid!(record, schema)
    %i[open strict].each do |mode|
      expect(EvalsSchema.errors(record, schema:, strict: mode == :strict)).to eq([]), "#{schema} (#{mode})"
    end
  end

  def created!(header = EvalRecords.header, scope: header.fetch("scope"))
    expect(store.create_record(scope:, header:)).to eq(:created)
    header
  end

  def leased(eval_run_id = run_id, scope: self.scope)
    store.acquire_lease(scope:, eval_run_id:)
  end

  def trial!(lease, line, eval_run_id: line.fetch("eval_run_id"))
    store.append_trial(scope:, eval_run_id:, line:, lease:)
  end

  def trials(eval_run_id = run_id, scope: self.scope) = store.each_trial(scope:, eval_run_id:).to_a
  def segments(eval_run_id = run_id, scope: self.scope) = store.each_segment(scope:, eval_run_id:).to_a

  def json(value) = EvalRecords.json(value)
  def empty_listing = { "records" => [], "next" => nil, "unreadable" => [] }

  # A copy of the record whose field reads from the Hash's default: the
  # field is answered, but its JSON does not hold it.
  def defaulted(record, field)
    Hash.new { |_, key| key == field ? record[field] : nil }.tap do |copy|
      record.each { |key, value| copy[key] = value unless key == field }
    end
  end

  describe "creating a record" do
    it "creates it once: a second create returns :exists and never clobbers the header" do
      header = created!
      changed = header.merge("idempotency_key" => "another-key")

      expect(store.create_record(scope:, header: changed)).to eq(:exists)
      expect(store.create_record(scope:, header:)).to eq(:exists)
      expect(json(store.read_header(scope:, eval_run_id: run_id))).to eq(json(header))
    end

    it "files a header of any kind, the reserved try and online included, keeping fields it does not know" do
      %w[try online rescore].each_with_index do |kind, index|
        header = EvalRecords.header_for(EvalRecords.run_id(index + 1)).merge("kind" => kind, "later" => { "a" => [1] })
        created!(header)

        read = store.read_header(scope:, eval_run_id: header["eval_run_id"])
        expect(json(read)).to eq(json(header))
        expect(EvalsSchema.errors(read, schema: "record-header", strict: false)).to eq([])
      end
    end

    it "refuses a header it cannot file: another scope, or no id, time or suite name it can read" do
      header = EvalRecords.header
      broken = [header.merge("scope" => other_scope), header.except("eval_run_id"),
                header.merge("eval_run_id" => "er_short"), header.merge("created_at" => "yesterday"),
                header.merge("created_at" => "2026-11-21T07:30:03.1234567Z"), header.except("suite"),
                header.merge("suite" => { "name" => "Not A Name" }), header.merge("format" => "smith.evals.trial")]

      broken.each do |value|
        expect { store.create_record(scope:, header: value) }.to raise_error(ArgumentError), value.keys.inspect
      end
      expect(store.read_header(scope:, eval_run_id: run_id)).to be_nil
      expect(store.list_records(scope:)).to eq(empty_listing)
    end

    # Each field is checked as the store will keep it: a Hash whose default
    # answers a read, or a subclass whose [] does, holds no such field in
    # its JSON, so the record is refused rather than kept without it.
    it "checks the record as it will keep it, so a Hash whose reads differ from its JSON is refused" do
      header = EvalRecords.header
      liar = Class.new(Hash) { def [](key) = key == "created_at" ? "2026-11-21T07:30:03.725Z" : super }
      headers = %w[format eval_run_id scope created_at suite].map { defaulted(header, _1) }
      headers << liar.new.merge!(header.except("created_at"))
      headers.each do |value|
        expect { store.create_record(scope:, header: value) }.to raise_error(ArgumentError), value.keys.inspect
      end
      expect(store.list_records(scope:)).to eq(empty_listing)
      created!
      lease = leased
      line = EvalRecords.trial_for(run_id, 1)
      segment = EvalRecords.segment_for(run_id)
      summary = EvalRecords.first_summary
      %w[format eval_run_id trial_id trial_revision].each do |field|
        expect { trial!(lease, defaulted(line, field), eval_run_id: run_id) }.to raise_error(ArgumentError), field
      end
      %w[format eval_run_id segment].each do |field|
        expect { store.append_segment(scope:, eval_run_id: run_id, segment: defaulted(segment, field), lease:) }
          .to raise_error(ArgumentError), field
      end
      %w[format eval_run_id scope summary_revision status].each do |field|
        expect { store.write_summary(scope:, eval_run_id: run_id, summary: defaulted(summary, field), lease:) }
          .to raise_error(ArgumentError), field
      end
      expect([trials, segments, store.read_summary(scope:, eval_run_id: run_id)]).to eq([[], [], nil])
      expect(store.list_records(scope:)["records"].map { _1["status"] }).to eq(["running"])
    end
  end

  describe "reading back" do
    it "reads every record back byte for byte, each valid against its contract schema, open and strict" do
      created!
      lease = leased
      EvalRecords.segments.each { store.append_segment(scope:, eval_run_id: run_id, segment: _1, lease:) }
      EvalRecords.trials.each { trial!(lease, _1) }
      store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:)
      expect(json(store.read_summary(scope:, eval_run_id: run_id))).to eq(json(EvalRecords.first_summary))
      store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.summary, lease:)

      header = store.read_header(scope:, eval_run_id: run_id)
      summary = store.read_summary(scope:, eval_run_id: run_id)
      expect([header, summary].map { json(_1) }).to eq([EvalRecords.header, EvalRecords.summary].map { json(_1) })
      expect(segments.map { json(_1) }).to eq(EvalRecords.text("segments.jsonl").lines(chomp: true))
      expect(trials.map { json(_1) }).to eq(EvalRecords.text("trials.jsonl").lines(chomp: true))
      valid!(header, "record-header")
      valid!(summary, "summary")
      segments.each { valid!(_1, "segment") }
      trials.each { valid!(_1, "trial") }
    end

    it "keeps every JSON value exactly: text in any script, escapes, big and signed numbers, order, emptiness" do
      output = { "astral" => "😀 \u{1F600}", "scripts" => "é ü 中文 ع", "controls" => (0..31).map(&:chr).join,
                 "separators" => "\u2028\u2029\u007f", "escapes" => "\"\\/",
                 "big" => (2**53) - 1, "small" => 1 - (2**53),
                 "floats" => [-0.0, 1.0, 5e-324, 1.7976931348623157e308, 1e21, 1.0 / 3, 0.1 + 0.2],
                 "literals" => [nil, true, false], "empty" => { "a" => [], "b" => {}, "c" => "" },
                 "order" => { "z" => 1, "a" => 2, "m" => 3 }, "deep" => (1..60).reduce(1) { |inner, _| [inner] } }
      line = EvalRecords.trial_for(run_id, 1, output:)
      created!
      trial!(leased, line)

      read = trials.first
      expect(json(read)).to eq(json(line))
      typed = ->(values) { values.map { [_1.class, _1.to_s] } }
      expect(typed.call(read.dig("output", "floats"))).to eq(typed.call(output["floats"]))
      expect(read.dig("output", "order").keys).to eq(%w[z a m])
      valid!(read, "trial")
    end

    it "refuses what JSON cannot hold exactly, or what has no canonical JSON, and stores nothing of it" do
      created!
      lease = leased
      odd = [{ a: 1 }, :symbol, Time.utc(2026), Float::NAN, Float::INFINITY, "\xFF".b, "é".encode("ISO-8859-1"),
             Rational(1, 3), { 1 => 2 }, Object.new, (1..64).reduce(1) { |inner, _| [inner] }, 2**53, -(2**53), 1e20]

      odd.each do |value|
        line = EvalRecords.trial_for(run_id, 1, output: value)
        expect { trial!(lease, line) }.to raise_error(ArgumentError), value.class.name
      end
      %w[not-a-hash].push([], nil).each do |value|
        expect { trial!(lease, value, eval_run_id: run_id) }.to raise_error(ArgumentError)
      end
      expect(trials).to eq([])
    end

    it "hands out frozen copies, so a caller's later change never reaches what it stored" do
      created!
      line = EvalRecords.trial_for(run_id, 1, output: { "category" => "billing" })
      trial!(leased, line)
      line["outcome"] = "error"
      line["output"]["category"] = "shipping"

      read = trials.first
      expect(read.values_at("outcome", "output")).to eq(["scored", { "category" => "billing" }])
      expect([read, read["output"], read["steps"], read.dig("steps", 0, "messages", 0)]).to all(be_frozen)
      expect { read["outcome"] << "!" }.to raise_error(FrozenError)
      expect(trials.first).to eq(read)
    end

    it "reads nothing for a run it does not hold" do
      expect(store.read_header(scope:, eval_run_id: run_id)).to be_nil
      expect(store.read_summary(scope:, eval_run_id: run_id)).to be_nil
      expect(store.cancel_request(scope:, eval_run_id: run_id)).to be_nil
      expect([trials, segments]).to eq([[], []])
      expect(store.list_records(scope:)).to eq(empty_listing)
    end
  end

  describe "the lease" do
    it "raises RunBusy for a second lease until the first is released, and refuses one for no record" do
      expect { leased }.to raise_error(ArgumentError, /no eval run #{run_id}/)
      created!
      lease = leased

      expect { leased }.to raise_error(Smith::Evals::RunBusy, /#{run_id}/)
      expect(lease.release).to be_nil
      expect(lease.release).to be_nil
      expect(lease).to be_released
      leased.release
    end

    it "takes writes only under the run's live lease from this store" do
      created!
      other = created!(EvalRecords.header_for(EvalRecords.run_id(2)))
      line = EvalRecords.trial_for(run_id, 1)
      other_store.create_record(scope:, header: EvalRecords.header)
      foreign = other_store.acquire_lease(scope:, eval_run_id: run_id)
      released = leased.tap(&:release)
      others = leased(other.fetch("eval_run_id"))

      [nil, released, others, foreign, Object.new].each do |lease|
        expect { trial!(lease, line) }.to raise_error(ArgumentError, /lease/)
        expect { store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:) }
          .to raise_error(ArgumentError, /lease/)
      end
      expect([trials, store.read_summary(scope:, eval_run_id: run_id)]).to eq([[], nil])
    end
  end

  describe "appending" do
    it "enumerates lines in append order, lazily, so an enumerator taken first sees later lines" do
      created!
      early = store.each_trial(scope:, eval_run_id: run_id)
      lease = leased
      EvalRecords.trials.each { trial!(lease, _1) }

      expect(early).to be_a(Enumerator)
      expect(early.map { _1.values_at("trial_id", "trial_revision") })
        .to eq(EvalRecords.trials.map { _1.values_at("trial_id", "trial_revision") })
    end

    # A read yields the lines there when it began, so a pass that appends
    # (a rerun's revision 2, say) never reads, and reruns, its own lines.
    it "reads a snapshot: the lines there when the read began, never one appended during it" do
      created!
      lease = leased
      3.times { trial!(lease, EvalRecords.trial_for(run_id, _1)) }
      store.append_segment(scope:, eval_run_id: run_id, segment: EvalRecords.segment_for(run_id, 1), lease:)
      read = store.each_trial(scope:, eval_run_id: run_id).map do |line|
        trial!(lease, line.merge("trial_revision" => 2))
        line["trial_id"]
      end
      launches = []
      store.each_segment(scope:, eval_run_id: run_id) do |segment|
        launches << segment["segment"]
        break if launches.size > 3

        store.append_segment(scope:, eval_run_id: run_id, lease:,
                             segment: EvalRecords.segment_for(run_id, segment["segment"] + 1))
      end
      reader = store.each_trial(scope:, eval_run_id: run_id)
      first = reader.next
      trial!(lease, EvalRecords.trial_for(run_id, 9))
      rest = []
      loop { rest << reader.next }

      expect(read).to eq(3.times.map { EvalRecords.trial_id(_1) })
      expect(launches).to eq([1])
      expect([first, *rest].size).to eq(6)
      expect([trials.size, segments.size]).to eq([7, 2])
    end

    it "keeps an identical re-append once, and refuses a different line with the same trial or launch" do
      created!
      lease = leased
      line = EvalRecords.trial_for(run_id, 1)
      segment = EvalRecords.segment_for(run_id, 1)

      expect(trial!(lease, line)).to eq(:appended)
      expect(trial!(lease, JSON.parse(json(line)))).to eq(:exists)
      expect { trial!(lease, line.merge("outcome" => "error")) }.to raise_error(ArgumentError, /different line/)
      expect(trial!(lease, line.merge("trial_revision" => 2))).to eq(:appended)
      expect(store.append_segment(scope:, eval_run_id: run_id, segment:, lease:)).to eq(:appended)
      expect(store.append_segment(scope:, eval_run_id: run_id, segment:, lease:)).to eq(:exists)
      expect { store.append_segment(scope:, eval_run_id: run_id, segment: segment.merge("resumed" => true), lease:) }
        .to raise_error(ArgumentError, /different line/)
      expect(trials.map { _1["trial_revision"] }).to eq([1, 2])
      expect(segments.size).to eq(1)
    end

    # Another json version may escape or order a record's text otherwise:
    # the same record is the same canonical JSON (RFC 8785), so a retry from
    # such a process, under a lease of its own, is :exists, and the text
    # first kept stays.
    it "knows a record by its canonical JSON, so another json version's text or key order is the same record" do
      created!
      lease = leased
      line = EvalRecords.trial_for(run_id, 1, output: { "text" => "é/ü 😀", "n" => 1.5 })
      segment = EvalRecords.segment_for(run_id, 1)
      kept = [trial!(lease, line), store.append_segment(scope:, eval_run_id: run_id, segment:, lease:),
              store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:)]
      texts = [trials, segments, [store.read_summary(scope:, eval_run_id: run_id)]].map { _1.map { |r| json(r) } }
      lease.release
      lease = leased # as a resumed runner would, reading what is stored
      %i[generate pretty_generate].each do |name|
        allow(JSON).to(receive(name).and_wrap_original { |original, value, *| original.call(value, ascii_only: true) })
      end
      again = [trial!(lease, line), trial!(lease, line.to_a.reverse.to_h),
               store.append_segment(scope:, eval_run_id: run_id, segment: segment.to_a.reverse.to_h, lease:),
               store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:),
               store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary.to_a.reverse.to_h,
                                   lease:)]
      %i[generate pretty_generate].each { allow(JSON).to receive(_1).and_call_original }

      expect([kept, again]).to eq([%i[appended appended written], %i[exists exists exists exists exists]])
      expect([trials, segments, [store.read_summary(scope:, eval_run_id: run_id)]].map { _1.map { |r| json(r) } })
        .to eq(texts)
    end

    # RFC 8785 writes a number by its value: 1.0 is 1, and -0.0 is 0.
    it "knows a number by its value, as RFC 8785 writes it: 1.0 is 1 and -0.0 is 0, the first text kept" do
      created!
      lease = leased
      first = EvalRecords.trial_for(run_id, 1, output: { "s" => 1.0, "z" => -0.0, "h" => 0.5 })

      expect(trial!(lease, first)).to eq(:appended)
      expect(trial!(lease, EvalRecords.trial_for(run_id, 1, output: { "s" => 1, "z" => 0, "h" => 0.5 })))
        .to eq(:exists)
      expect { trial!(lease, EvalRecords.trial_for(run_id, 1, output: { "s" => 1, "z" => 0, "h" => 0.25 })) }
        .to raise_error(ArgumentError, /different line/)
      expect(trials.map { json(_1) }).to eq([json(first)])
    end

    it "refuses a line for another run, of another kind, without its id, or past 8 MiB" do
      created!
      lease = leased
      line = EvalRecords.trial_for(run_id, 1)
      bound = 8 * 1024 * 1024
      filler = bound - json(line.merge("output" => "")).bytesize

      [line.merge("eval_run_id" => EvalRecords.run_id(9)), EvalRecords.segment_for(run_id), line.except("trial_id"),
       line.merge("trial_revision" => 0), line.merge("output" => "x" * (filler + 1))].each do |bad|
        expect { trial!(lease, bad, eval_run_id: run_id) }.to raise_error(ArgumentError)
      end
      ["tr_short", "tr_#{"A" * 32}", "tr_#{"0" * 33}", EvalRecords.run_id(1), 7].each do |trial_id|
        expect { trial!(lease, line.merge("trial_id" => trial_id)) }.to raise_error(ArgumentError), trial_id.to_s
      end
      expect { store.append_segment(scope:, eval_run_id: run_id, segment: line, lease:) }.to raise_error(ArgumentError)
      [0, -1, "1", 1.0, nil].each do |number|
        segment = EvalRecords.segment_for(run_id).merge("segment" => number)
        expect { store.append_segment(scope:, eval_run_id: run_id, segment:, lease:) }
          .to raise_error(ArgumentError), number.inspect
      end
      expect(trial!(lease, line.merge("output" => "x" * filler))).to eq(:appended)
      expect(trials.map { json(_1).bytesize }).to eq([bound])
    end

    it "keeps every line from eight threads appending at once under one lease" do
      created!
      lease = leased
      8.times.map do |thread|
        Thread.new { 25.times { trial!(lease, EvalRecords.trial_for(run_id, (thread * 100) + _1)) } }
      end.each(&:join)

      numbers = trials.map { _1.fetch("trial_id").delete_prefix("tr_").to_i(16) }
      expect(numbers.sort).to eq(8.times.flat_map { |thread| 25.times.map { (thread * 100) + _1 } })
      expect(numbers.group_by { _1 / 100 }.values).to all(satisfy { _1 == _1.sort })
    end
  end

  describe "the summary" do
    it "refuses a revision not above the stored one; the stored summary written again changes nothing" do
      created!
      lease = leased
      first = EvalRecords.first_summary
      write = ->(summary) { store.write_summary(scope:, eval_run_id: run_id, summary:, lease:) }

      expect(write.call(first)).to eq(:written)
      expect(write.call(JSON.parse(json(first)))).to eq(:exists)
      expect { write.call(first.merge("status" => "failed")) }.to raise_error(ArgumentError, /revision 1/)
      expect(write.call(EvalRecords.summary)).to eq(:written)
      expect { write.call(first) }.to raise_error(ArgumentError, /revision 1 is not above the stored 2/)
      [first.merge("summary_revision" => 3, "scope" => other_scope), first.merge("summary_revision" => 0),
       first.merge("summary_revision" => 3, "eval_run_id" => EvalRecords.run_id(9)),
       first.merge("summary_revision" => 3, "status" => "running")].each do |bad|
        expect { write.call(bad) }.to raise_error(ArgumentError)
      end
      expect(json(store.read_summary(scope:, eval_run_id: run_id))).to eq(json(EvalRecords.summary))
    end
  end

  describe "cancelling" do
    let(:actor) { Smith::Evals::Actor.person("usr_51a8") }

    it "is idempotent: the first request stands" do
      created!

      expect(store.request_cancel(scope:, eval_run_id: run_id, actor:, reason: "wrong dataset")).to eq(:requested)
      expect(store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.service("svc_1"),
                                  reason: nil)).to eq(:exists)
      expect(store.cancel_request(scope:, eval_run_id: run_id))
        .to eq("actor" => { "kind" => "person", "id" => "usr_51a8" }, "reason" => "wrong dataset",
               "at" => EvalRecords::CLOCK_AT.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"))
    end

    it "needs no lease, and refuses an unknown run, an actor it cannot record or a reason past 1,024 characters" do
      created!
      lease = leased

      expect { store.request_cancel(scope:, eval_run_id: EvalRecords.run_id(9), actor:, reason: nil) }
        .to raise_error(ArgumentError, /no eval run/)
      expect { store.request_cancel(scope:, eval_run_id: run_id, actor: "usr_51a8", reason: nil) }
        .to raise_error(ArgumentError)
      expect { store.request_cancel(scope:, eval_run_id: run_id, actor:, reason: "x" * 1025) }
        .to raise_error(ArgumentError)
      expect(store.request_cancel(scope:, eval_run_id: run_id, actor: actor.to_h, reason: "é" * 1024))
        .to eq(:requested)
      expect(store.cancel_request(scope:, eval_run_id: run_id)).to include("reason" => "é" * 1024)
      lease.release
    end

    it "records its clock's time in UTC, never changing the Time the clock gives" do
      at = Time.new(2026, 11, 22, 10, 1, 2.5r, "+02:00")
      clocked = store_with(clock: -> { at })
      clocked.create_record(scope:, header: EvalRecords.header)

      expect(clocked.request_cancel(scope:, eval_run_id: run_id, actor:, reason: nil)).to eq(:requested)
      expect(clocked.cancel_request(scope:, eval_run_id: run_id)["at"]).to eq("2026-11-22T08:01:02.500Z")
      expect([at.utc_offset, at.utc?]).to eq([7200, false])
    end
  end

  describe "listing" do
    # Newest first by created_at as a time (a shorter fraction is not a later
    # time), then by id, highest first.
    let(:times) do
      { 1 => "2026-11-21T07:30:03Z", 2 => "2026-11-21T07:30:03.5Z", 3 => "2026-11-21T07:30:03.000001Z",
        4 => "2026-11-22T00:00:00Z", 5 => "2026-11-20T12:00:00.123Z", 6 => "2026-11-20T12:00:00.123Z" }
    end

    def listed!(number, created_at, suite: nil)
      created!(EvalRecords.header_for(EvalRecords.run_id(number), created_at:, suite:))
    end

    def walk(limit:, after: nil)
      store.list_records(scope:, limit:, after:).then { [_1["records"].map { |entry| entry["eval_run_id"] }, _1] }
    end

    it "lists newest first, each record with its suite, time and status" do
      times.each { |number, created_at| listed!(number, created_at, suite: number == 3 ? "support.other" : nil) }
      lease = leased(EvalRecords.run_id(4))
      store.write_summary(scope:, eval_run_id: EvalRecords.run_id(4), lease:,
                          summary: EvalRecords.summary_for(EvalRecords.run_id(4), status: "cancelled"))

      listing = store.list_records(scope:)
      expect(listing["records"].map { _1["eval_run_id"] }).to eq([4, 2, 3, 1, 6, 5].map { EvalRecords.run_id(_1) })
      expect(listing["records"].first(3)).to eq(
        [{ "eval_run_id" => EvalRecords.run_id(4), "suite" => "support.ticket_triage", "created_at" => times[4],
           "status" => "cancelled" },
         { "eval_run_id" => EvalRecords.run_id(2), "suite" => "support.ticket_triage", "created_at" => times[2],
           "status" => "running" },
         { "eval_run_id" => EvalRecords.run_id(3), "suite" => "support.other", "created_at" => times[3],
           "status" => "running" }]
      )
      expect(listing["next"]).to be_nil
      expect(listing["unreadable"]).to eq([])
      expect([listing, listing["records"], listing["unreadable"]]).to all(be_frozen)
    end

    it "walks every record once with its cursor, records added meanwhile only where they fall" do
      times.each { |number, created_at| listed!(number, created_at) }
      first, page = walk(limit: 2)
      listed!(7, "2026-11-23T00:00:00Z")
      listed!(8, "2026-11-19T00:00:00Z")
      seen = first
      while page["next"]
        ids, page = walk(limit: 2, after: page["next"])
        seen += ids
      end

      expect(first).to eq([4, 2].map { EvalRecords.run_id(_1) })
      expect(seen).to eq([4, 2, 3, 1, 6, 5, 8].map { EvalRecords.run_id(_1) })
      expect(walk(limit: 3).first).to eq([7, 4, 2].map { EvalRecords.run_id(_1) })
      expect(walk(limit: 8).last["next"]).to be_nil
    end

    it "refuses a limit outside 1 to 1,000 and a cursor it did not give" do
      [0, 1001, "2", nil, 2.0].each do |limit|
        expect { store.list_records(scope:, limit:) }.to raise_error(ArgumentError, /limit/)
      end
      ["garbage", 7, "2026-11-21T07:30:03Z", "2026-11-21T07:30:03Z,er_short"].each do |after|
        expect { store.list_records(scope:, after:) }.to raise_error(ArgumentError, /cursor/)
      end
    end
  end

  describe "scopes" do
    it "never shows one scope's records to another" do
      mine = created!
      theirs = created!(EvalRecords.header_for(run_id, scope: other_scope))
      mine_lease = leased
      their_lease = leased(scope: other_scope)
      trial!(mine_lease, EvalRecords.trial_for(run_id, 1))
      store.write_summary(scope: other_scope, eval_run_id: run_id, lease: their_lease,
                          summary: EvalRecords.summary_for(run_id, scope: other_scope))
      store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: nil)

      expect(store.read_header(scope: { tenant: "ten_0193", project: "prj_ticket_triage" }, eval_run_id: run_id))
        .to eq(mine)
      expect(store.read_header(scope: other_scope, eval_run_id: run_id)).to eq(theirs)
      expect([trials.size, trials(scope: other_scope).size]).to eq([1, 0])
      expect(store.read_summary(scope:, eval_run_id: run_id)).to be_nil
      expect(store.cancel_request(scope: other_scope, eval_run_id: run_id)).to be_nil
      expect(store.list_records(scope: other_scope)["records"].map { _1["status"] }).to eq(["succeeded"])
      expect(store.list_records(scope: { "tenant" => "ten_0300" })["records"]).to eq([])
      expect { store.read_header(scope: { "Tenant" => "x" }, eval_run_id: run_id) }.to raise_error(Smith::ScopeInvalid)
    end
  end

  describe "ids" do
    it "refuses an id that could name another path, or alias one on a case-insensitive file system" do
      created!
      ids = ["er_../../../../etc", "../#{run_id}", "#{run_id}/..", run_id.upcase, "er_#{run_id[3..].upcase}",
             "#{run_id}\u0000", run_id[0..-2], "#{run_id}0", nil, 7]
      calls = %i[read_header read_summary cancel_request each_trial each_segment acquire_lease]

      ids.each do |eval_run_id|
        calls.each do |call|
          expect { store.public_send(call, scope:, eval_run_id:) }
            .to raise_error(ArgumentError), "#{call} #{eval_run_id.inspect}"
        end
        expect { store.create_record(scope:, header: EvalRecords.header.merge("eval_run_id" => eval_run_id)) }
          .to raise_error(ArgumentError)
      end
    end
  end

  describe "racing threads" do
    it "create a record once and lease it once" do
      header = EvalRecords.header
      created = 8.times.map { Thread.new { store.create_record(scope:, header:) } }.map(&:value)
      leases = 8.times.map do
        Thread.new do
          leased
        rescue Smith::Evals::RunBusy
          :busy
        end
      end.map(&:value)

      expect(created.tally).to eq(created: 1, exists: 7)
      expect(leases.count(:busy)).to eq(7)
    end
  end
end
