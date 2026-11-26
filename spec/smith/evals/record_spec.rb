# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "tmpdir"
require "smith/evals"
require "smith/testing"

# A run's record as a reader sees it (slice-1a design, 4.6), and what a
# trial line keeps of a subject's output and state (5.4).
RSpec.describe Smith::Evals::Record do
  examples = File.expand_path("../../../docs/evals/examples/records/failing-rerun", __dir__)

  def lines(name, folder) = File.readlines(File.join(folder, name)).map { JSON.parse(_1) }

  describe "reading a stored run" do
    let(:store) { Smith::Evals::Stores::Memory.new }
    let(:header) { JSON.parse(File.read(File.join(examples, "header.json"))) }
    let(:scope) { header["scope"] }
    let(:run_id) { header["eval_run_id"] }

    before do
      store.create_record(scope:, header:)
      lease = store.acquire_lease(scope:, eval_run_id: run_id)
      lines("segments.jsonl", examples).each { store.append_segment(scope:, eval_run_id: run_id, segment: _1, lease:) }
      lines("trials.jsonl", examples).each { store.append_trial(scope:, eval_run_id: run_id, line: _1, lease:) }
      lease.release
    end

    it "gives each trial's effective line once, its highest revision, in the order those lines were appended" do
      record = Smith::Evals.record(run_id, scope:, store:)
      all = lines("trials.jsonl", examples)
      reran = all.select { _1["trial_revision"] == 2 }.map { _1["trial_id"] }
      effective = record.each_trial.to_a

      expect(reran.size).to eq(2)
      expect(effective.size).to eq(111)
      expect(effective).to eq(all.reject { reran.include?(_1["trial_id"]) && _1["trial_revision"] == 1 })
      expect(effective.select { reran.include?(_1["trial_id"]) }.map { _1["trial_revision"] }).to eq([2, 2])
      expect(record.each_line.count).to eq(113)
      expect([record.header, record.segments.size, record.summary]).to eq([header, 3, nil])
    end

    it "is nil for a run the store does not hold in the scope" do
      expect(Smith::Evals.record("er_#{"0" * 32}", scope:, store:)).to be_nil
      expect(Smith::Evals.record(run_id, scope: { "tenant" => "ten_other" }, store:)).to be_nil
    end
  end

  describe "a trial line's output and state" do
    include_context "with an eval run suite"

    it "keeps output past 64 KiB and kept state past 1 MiB as null, with the gaps output_cut and state_cut" do
      klass = with_stubbed_class("SpecEvalBulky", SpecEvalTriage) do
        transition(:check, from: :new, to: :checked) do
          run { |step| step.write_context(:notes, { "text" => "y" * (1024 * 1024) }) }
        end
      end
      Smith::Testing.stub_agent(:spec_eval_classifier,
                                outputs: ->(_request) { { category: "x" * (65 * 1024), priority: "low" } })
      run = run_suite(suite(workflow: klass, trials: 1, keep: %i[notes triage]))
      line = run.record.each_trial.first

      expect(line.values_at("output", "state")).to eq([nil, nil])
      expect(line["recording"].values_at("gaps", "complete")).to eq([%w[output_cut state_cut], false])
      expect(line["outcome"]).to eq("scored")
      expect(EvalsSchema.errors(line, schema: "trial", strict: true)).to eq([])
    end

    it "keeps output of exactly 64 KiB of canonical JSON, and none a byte longer" do
      pad = 65_536 - Smith::CanonicalJSON.generate({ "category" => "", "priority" => "low" }).bytesize
      Smith::Testing.stub_agent(:spec_eval_classifier, outputs: lambda { |request|
        long = request.messages.find { _1["role"] == "user" }["text"].include?("s-02")
        { category: "x" * (long ? pad + 1 : pad), priority: "low" }
      })
      lines = run_suite(suite(trials: 1)).record.each_trial.to_h { [_1["sample_id"], _1] }

      expect(Smith::CanonicalJSON.generate(lines["s-01"]["output"]).bytesize).to eq(65_536)
      expect(lines["s-01"]["recording"]["gaps"]).to eq([])
      expect([lines["s-02"]["output"], lines["s-02"]["recording"]["gaps"]]).to eq([nil, ["output_cut"]])
    end
  end

  # The reference generator wrote the published headers by design 8.6 and
  # 8.7; Smith writes the same one for the same suite, dataset and start.
  describe "a header" do
    examples_root = File.expand_path("../../../docs/evals/examples", __dir__)

    around do |example|
      Dir.mktmpdir("smith-evals-header") do |dir|
        FileUtils.mkdir_p(File.join(dir, "evals"))
        FileUtils.cp_r(File.join(examples_root, "dataset/support-tickets"), File.join(dir, "evals/support_tickets"))
        root = Smith::Evals.config.dataset_root
        Smith::Evals.config.dataset_root = "evals"
        Dir.chdir(dir) { example.run }
      ensure
        Smith::Evals.config.dataset_root = root
      end
    end

    it "is the published passing record's, but for the Ruby it ran on" do
      published = JSON.parse(File.read(File.join(examples_root, "records/passing/header.json")))
      with_stubbed_class("TicketTriage", Smith::Workflow) do
        initial_state :new
        state :triaged
        transition(:classify, from: :new, to: :triaged) { compute { |_step| nil } }
      end
      suite = Class.new(Smith::Evals::Suite) do
        suite_name "support.ticket_triage"
        dataset "support_tickets"
        subject workflow: TicketTriage, input: ->(sample) { { ticket: sample.input[:text] } }, keep: %i[triage]
        trials 3, reduce: :majority
        concurrency 2
        scorer(:category, version: 1) { |_sample, _trial| Smith::Evals::Score.pass }
        scorer(:priority, version: 2, also: [:mean]) { |_sample, _trial| Smith::Evals::Score.pass }
        gate :category_floor, scorer: :category, at_least: 0.8
        budget max_cost_nanos: 250_000_000
      end
      config = Smith::Evals::Configuration.new.tap { _1.host_code_version = "9b27c3f" }
      plan = Smith::Evals::Plan.new(suite, scope: published["scope"])
      header = described_class.header(plan, eval_run_id: published["eval_run_id"],
                                            idempotency_key: "nightly-2026-11-22",
                                            started_by: Smith::Evals::Actor.service("svc_nightly_evals"),
                                            created_at: Time.iso8601(published["created_at"]), config:)

      running = published["environment"].merge("smith_version" => Smith::VERSION, "ruby_version" => RUBY_VERSION)
                                        .merge("execution_semantics_version" => Smith::EXECUTION_SEMANTICS_VERSION)
      expect(JSON.generate(header.except("scope")))
        .to eq(JSON.generate(published.except("scope").merge("environment" => running)))
      expect(header["scope"]).to eq(Smith::Scope.build(published["scope"])) # Smith's scope sorts its keys
    end
  end
end
