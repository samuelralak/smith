# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# What slice 5a adds to a run (slice 5a design, section 2): `samples:` (ids
# within the suite's selection, the header's narrowing), `trials:`,
# `candidate:` (a tuning candidate: its header reference and its texts, sent
# through Smith::Prompts.with_candidate) and `kind:`.
RSpec.describe "Smith::Evals.run with samples, trials, a candidate and a kind" do
  include_context "with an eval run suite"

  let(:sent) { Queue.new }
  let(:base) { "Sort the ticket into a category and a priority." }
  let(:better) { "Sort the ticket exactly: its category and priority." }
  let(:tuning_run) { format("tu_%032x", 7) }
  let(:candidate_class) { Data.define(:reference, :texts) }

  before do
    define_prompted
    queue = sent
    answering = method(:answer)
    outputs = lambda do |request|
      queue << request.messages.find { _1["role"] == "system" }["text"]
      answering.call(request)
    end
    Smith::Testing.stub_agent(:spec_prompted_classifier, usage: { input_tokens: 100, output_tokens: 20 }, outputs:)
  end

  def define_prompted
    rules = Smith::Prompt.new("triage.rules", base)
    with_stubbed_class("SpecPromptedClassifier", Smith::Agent) do
      register_as :spec_prompted_classifier
      model "claude-haiku-4-5", provider: :anthropic
      instructions rules
      output_schema SpecEvalSchema
    end
    with_stubbed_class("SpecPromptedTriage", Smith::Workflow) do
      initial_state :new
      %i[triaged failed].each { state _1 }
      seed_messages { |context| [{ role: :user, content: context[:ticket] }] }
      transition :classify, from: :new, to: :triaged do
        execute :spec_prompted_classifier, output_to: :triage
        on_failure :fail
      end
    end
  end

  def prompted(**) = suite(workflow: SpecPromptedTriage, **)

  # A candidate as a tuning run hands one over: its texts, and its header
  # reference naming each component's version.
  def candidate(text = better, version: Smith::Prompt.new("triage.rules", text).version, id: 1)
    reference = { "candidate_id" => format("cd_%032x", id), "tuning_run_id" => tuning_run,
                  "components" => [{ "id" => "triage.rules", "version" => version }] }
    candidate_class.new(reference:, texts: { "triage.rules" => text })
  end

  def drained = Array.new(sent.size) { sent.pop }

  it "runs only the samples named, each its given number of times, and says so in its header" do
    ids = %w[s-07 s-02 s-05]
    run = run_suite(prompted, samples: ids, trials: 1)
    header, _segments, lines, summary = record_of(run)
    whole = prompted.selection(scope: eval_scope)

    expect(lines.map { _1["sample_id"] }.sort).to eq(ids.sort)
    expect(header["selection"]).to eq("split" => "dev", "narrow" => { "ids" => ids.sort }, "sample_count" => 3,
                                      "sample_ids_digest" => Smith::Evals::Identity.sample_ids_digest(ids))
    expect(header["plan"].values_at("trials_per_sample", "planned_trials")).to eq([1, 3])
    expect(header.dig("suite", "measure_digest")).not_to eq(whole.measure_digest)
    expect(header.dig("suite", "version")).to eq(whole.manifest["version"])
    expect(header.values_at("kind", "candidate")).to eq(["eval", nil])
    expect(summary.dig("outcomes", "scored")).to eq(3)
  end

  it "refuses a sample the suite does not select, one named twice, or none, before anything is written" do
    { %w[s-02 s-99] => "samples names s-99, which the suite does not select",
      %w[s-02 s-02] => "samples names s-02 twice", [] => "samples names at least one sample" }.each do |ids, message|
      expect { run_suite(prompted, samples: ids) }.to raise_error(ArgumentError, message)
    end
    expect { run_suite(prompted, trials: 0) }.to raise_error(ArgumentError, "trials is an Integer from 1 to 100")
    expect(eval_store.list_records(scope: eval_scope)["records"]).to be_empty
  end

  it "sends the candidate's texts in place of the base ones, and names it in the header, every line and trial id" do
    chosen = candidate
    run = run_suite(prompted, samples: %w[s-01 s-02], trials: 1, candidate: chosen, kind: :tuning_minibatch)
    header, _segments, lines, = record_of(run)

    expect(drained.uniq).to eq([better])
    expect(header.values_at("kind", "candidate")).to eq(["tuning_minibatch", chosen.reference])
    expect(lines.map { _1["candidate_id"] }.uniq).to eq([chosen.reference["candidate_id"]])
    expect(lines.flat_map { _1["steps"] }.map { _1["components"] }.uniq)
      .to eq([[{ "id" => "triage.rules", "version" => chosen.reference.dig("components", 0, "version") }]])
    expect(lines.map { _1["trial_id"] }).to match_array(%w[s-01 s-02].map do |id|
      Smith::Evals::Identity.trial_id(eval_run_id: run.eval_run_id, sample_id: id, index: 0,
                                      candidate: chosen.reference["candidate_id"])
    end)
    [header, *lines].zip(["record-header", *Array.new(lines.size, "trial")]) do |document, schema|
      expect(schema_errors(document, schema)).to eq([])
    end
  end

  it "publishes the header's candidate in its shape: an id, a tuning run and each component's version" do
    header = record_of(run_suite(prompted, samples: %w[s-01], trials: 1, candidate: candidate)).first

    [{ "candidate_id" => "cd_1" }, header["candidate"].except("components")].each do |wrong|
      expect(schema_errors(header.merge("candidate" => wrong), "record-header")).not_to be_empty
    end
  end

  it "sends the base texts without a candidate" do
    run_suite(prompted, samples: %w[s-01], trials: 1)

    expect(drained).to eq([base])
  end

  it "refuses a known key asked for another candidate, naming it" do
    run_suite(prompted, samples: %w[s-01], trials: 1, candidate: candidate)

    expect { run_suite(prompted, samples: %w[s-01], trials: 1, candidate: candidate("Sort it.", id: 2)) }
      .to raise_error(Smith::Evals::ResumeMismatch) { expect(_1.fields).to eq(["candidate"]) }
  end

  it "refuses a candidate whose texts are not the versions it names, or without a reference" do
    wrong = candidate(version: Smith::Prompt.new("triage.rules", base).version)
    bare = candidate_class.new(reference: nil, texts: { "triage.rules" => better })

    { wrong => "the candidate's text for triage.rules is not the version its reference names",
      bare => "a candidate's reference names its candidate_id, tuning_run_id and components",
      { "triage.rules" => better } => "a candidate answers reference and texts" }.each do |given, message|
      expect { run_suite(prompted, samples: %w[s-01], candidate: given) }.to raise_error(ArgumentError, message)
    end
    expect(eval_store.list_records(scope: eval_scope)["records"]).to be_empty
  end

  it "takes an eval or a tuning kind, and refuses a kind reserved for later" do
    run = run_suite(prompted, samples: %w[s-01], trials: 1, candidate: candidate, kind: :tuning_validation)

    expect(record_of(run).first["kind"]).to eq("tuning_validation")
    %i[tuning_holdout try online rescore].each do |kind|
      expect { run_suite(prompted, samples: %w[s-01], kind:) }
        .to raise_error(ArgumentError, "kind is eval, tuning_minibatch or tuning_validation")
    end
  end
end
