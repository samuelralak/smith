# frozen_string_literal: true

require "smith/tuning"
require "smith/testing"

# The loop's seam as Smith runs it in one process (slice 5a design, section
# 2): each evaluation one eval run through Smith::Evals.run, each
# reflection a recorded trial through the in-process driver. It keeps the
# seam's contract, and the two free checks: the candidate reached the wire,
# and only training content is asked about.
RSpec.describe Smith::Tuning::Evaluation::InProcess do
  include_context "with a tuning run suite"

  let(:tuning_run) { format("tu_%032x", 5) }
  let(:prompts) { Smith::Prompts.components(SpecTunedQA) }
  let(:seed) { Smith::Tuning::Candidate.seed(prompts, components: texts.keys, tuning_run_id: tuning_run) }
  let(:candidate) { seed }
  let(:component) { "draft.predict" }
  let(:train_ids) { TuningRunSuite.ids("t", 12) }
  let(:validation_ids) { TuningRunSuite.ids("v", 31) }
  let(:suite) { tuning_suite }
  let(:trials) { seam(suite) }
  let(:capped) { trials.tap { ledger.instance_variable_set(:@admit, ledger.reserved) } }
  let(:good) { seed.child(component, TuningRunSuite::GOOD_DRAFT, iteration: 1, parent: 0) }

  def seam(suite)
    selection = suite.selection(scope: tuning_scope)
    described_class.new(suite:, scope: tuning_scope, store: tuning_store, started_by: nil, objective: "exact",
                        samples: selection.samples.to_h { [_1.id, _1] }, train_ids:, base_versions: seed.versions,
                        reflection: Smith::Tuning::Reflection::Runner.new(
                          Smith::Tuning::Settings::ReflectionModel.build(reflection_setting), scope: tuning_scope
                        ))
  end

  def minibatch(candidate, key, **)
    trials.evaluate(candidate, sample_ids: train_ids.first(3), kind: :tuning_minibatch, key:, **)
  end

  it_behaves_like "a tuning trials seam"

  it "scores each sample as its run did, one metric call a trial, and spends what the eval run's lines spent" do
    weak = minibatch(seed, "#{tuning_run}/1/parent", component:)
    strong = minibatch(good, "#{tuning_run}/1/child")
    record = Smith::Evals.record(strong.eval_run_id, scope: tuning_scope, store: tuning_store)

    expect([weak.mean, strong.mean]).to eq([0.0, 1.0])
    expect([strong.metric_calls, strong.provider_calls, strong.complete, strong.stop]).to eq([3, 12, true, nil])
    expect(strong.cost_nanos).to eq(record.each_trial.sum { _1.dig("usage", "cost_nanos") })
    expect(record.header.values_at("kind", "candidate")).to eq(["tuning_minibatch", good.reference])
  end

  it "asks the scorer's feedback on each training trial, its expected answer left for the reflection to withhold" do
    pass = minibatch(seed, "#{tuning_run}/1/parent", component:)

    expect(pass.samples.transform_values(&:feedback))
      .to eq(train_ids.first(3).to_h { [_1, "draft.predict: the answer should be answer #{_1}, not \"maybe #{_1}\""] })
    expect(asked_feedback).to eq(train_ids.first(3))
  end

  it "takes the score's explanation as feedback when the scorer gives none" do
    plain = Class.new(Smith::Evals::Scorer) do
      scorer_name :exact
      version 1
      def score(sample, trial) = Smith::Evals::Score.match(trial.state.dig(:answer, :text), sample.expected)
    end
    trials = seam(tuning_suite(scorer: plain))
    pass = trials.evaluate(seed, sample_ids: train_ids.first(1), kind: :tuning_minibatch, key: "k", component:)

    expect(pass.samples.values.map(&:feedback)).to eq(["expected answer t-000, got maybe t-000"])
  end

  it "refuses to ask about a sample outside training: only training content reaches a reflection" do
    mixed = [train_ids.first, validation_ids.first]

    expect { trials.evaluate(seed, sample_ids: mixed, kind: :tuning_minibatch, key: "k", component:) }
      .to raise_error(ArgumentError, "feedback is asked on training samples only; v-000 is not one")
    expect(asked_feedback).to be_empty
  end

  it "stops at candidate_not_sent when a step sent another version of a component the candidate changed" do
    dropping = Class.new(Smith::Evals::Drivers::InProcess) do
      def run(trial, context) = super(trial.with(candidate: nil), context)
    end
    suite.driver(dropping.new)

    expect(minibatch(seed, "#{tuning_run}/1/parent").stop).to be_nil
    expect(minibatch(good, "#{tuning_run}/1/child").stop).to eq(:candidate_not_sent)
  end

  it "stops at scorer_failed when the objective could not score a trial, which scores 0" do
    unsure = Class.new(Smith::Evals::Scorer) do
      scorer_name :exact
      version 1
      def score(sample, _trial)
        sample.id == "t-001" ? Smith::Evals::Score.unscored("no answer key") : Smith::Evals::Score.pass
      end
    end
    pass = seam(tuning_suite(scorer: unsure)).evaluate(seed, sample_ids: train_ids.first(3), kind: :tuning_minibatch,
                                                             key: "k")

    expect([pass.stop, pass.scores]).to eq([:scorer_failed, { "t-000" => 1.0, "t-001" => 0.0, "t-002" => 1.0 }])
  end

  it "stops with the reason of an error that stops every run" do
    Smith::Testing.reset!
    pass = minibatch(seed, "#{tuning_run}/1/parent")

    expect([pass.stop, pass.complete]).to eq([:configuration_error, false])
  end
end
