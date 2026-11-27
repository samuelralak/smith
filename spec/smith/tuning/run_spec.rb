# frozen_string_literal: true

require "smith/tuning"
require "smith/testing"

# A tuning run end to end on request-aware stubs, through Smith's own seam
# (slice 5a design, section 5, the pilot cut's done-when lines): a planted
# weak prompt improved; metric calls that are the trial lines that ran;
# validation content never shown to a reflection; the expected answer kept
# out of feedback unless the scorer opts in; the wire check; the cap; and
# every record valid against its schema.
RSpec.describe Smith::Tuning, ".run" do
  include_context "with a tuning run suite"

  let(:run_id) { Smith::Evals::Identity.tuning_run_id(key: tuning_key, scope: tuning_scope, suite: "spec.tuned_qa") }

  def tuned(suite = tuning_suite, **) = described_class.run(suite, **tuning_settings(**))

  def eval_runs(record)
    passes = record.iterations.flat_map { _1.values_at("minibatch", "validation") + [_1.dig("child", "minibatch")] }
    passes.compact.map { _1["eval_run_id"] }
  end

  def eval_record(id) = Smith::Evals.record(id, scope: tuning_scope, store: tuning_store)
  def shown(record) = JSON.generate(record.reflections.flat_map { |line| line["steps"].map { _1["messages"] } })

  # The reply, after the first `failures` calls find the provider overloaded.
  def failing(answer, failures)
    calls = 0
    overloaded = RubyLLM::OverloadedError.new(nil, "Overloaded")
    ->(request) { (calls += 1) <= failures ? raise(overloaded) : answer.call(request) }
  end

  def valid?(document, schema)
    %i[open strict].all? { EvalsSchema.errors(document, schema:, strict: _1 == :strict).empty? }
  end

  it "improves a planted weak prompt: the best beats the seed on validation with the stub's good text" do
    record = tuned

    expect(record.status).to eq(:finished)
    expect(record.ended).to eq(:proposal)
    expect(record.best.texts["draft.predict"]).to eq(TuningRunSuite::GOOD_DRAFT)
    expect(record.best.texts.except("draft.predict")).to eq(texts.except("draft.predict"))
    expect(record.candidates.map(&:mean)).to eq([0.0, 1.0])
    expect(record.summary["seed"]).to include("index" => 0, "mean" => 0.0)
    expect(record.summary["best"]).to include("index" => 1, "mean" => 1.0)
    expect(record.header["components"].map { _1["base_text"] }).to eq(texts.values)
  end

  it "counts as metric calls exactly the trial lines that ran across its eval runs, and spends what they spent" do
    record = tuned
    lines = eval_runs(record).flat_map { eval_record(_1).each_trial.to_a }
    reflections = record.reflections.sum { _1.dig("usage", "cost_nanos") }

    expect(record.metric_calls_used).to eq(lines.count { _1["outcome"] != "not_run" }).and(eq(101))
    expect(record.summary["validation_passes"]).to eq(2)
    expect(record.summary.dig("usage", "cost_nanos")).to eq(lines.sum { _1.dig("usage", "cost_nanos") } + reflections)
    expect(record.summary.dig("usage", "reflection_calls")).to eq(record.reflections.size).and(eq(2))
  end

  it "never shows a reflection a validation input, and asks feedback on training trials only" do
    record = tuned

    expect(shown(record)).to include("question t-0")
    expect(shown(record)).not_to include(TuningRunSuite::SEALED, "v-0")
    expect(asked_feedback).not_to be_empty
    expect(asked_feedback).to all(start_with("t-"))
  end

  it "withholds the expected answer from the feedback a reflection reads, unless the scorer opts in" do
    hidden = shown(tuned)
    opted = Class.new(TuningRunSuite.exact(feedback_asked)) { reveals_expected true }
    revealed = tuned(tuning_suite(scorer: opted), idempotency_key: "tune-2")

    expect(hidden).to include("the answer should be [withheld]")
    expect(hidden).not_to match(/answer t-\d{3}/)
    expect(shown(revealed)).to match(/the answer should be answer t-\d{3}/)
    expect(revealed.header.dig("objective", "reveals_expected")).to be(true)
  end

  # A reflection reads the minibatch trials' messages: a suite that keeps
  # none would leave it blind, so it is refused before anything is written.
  it "refuses a suite that records no content, writing nothing" do
    suite = tuning_suite
    suite.recording(content: false)

    expect { tuned(suite) }.to raise_error(ArgumentError, /records no content/)
    expect(tuning_store.read_tuning_header(scope: tuning_scope, tuning_run_id: run_id)).to be_nil
  end

  it "stops candidate_not_sent when its driver drops the candidate" do
    dropping = Class.new(Smith::Evals::Drivers::InProcess) do
      def run(trial, context) = super(trial.with(candidate: nil), context)
    end
    suite = tuning_suite
    suite.driver(dropping.new)
    record = tuned(suite)

    expect(record.summary.values_at("status", "ended", "candidates")).to eq(["failed", "failed", 1])
    expect(record.summary["stop"]["code"]).to eq("candidate_not_sent")
    expect(record.iterations.last["ended_as"]).to eq("incomplete")
  end

  # The pilot's cap: a trial the ledger refused did not run, so it is no
  # metric call and not in the pass; its eval run starts no more trials and
  # stops incomplete, and the tuning run writes no line for the iteration.
  # Called again with the cap raised, it replays the iteration under the
  # same keys, its eval runs going on from where they stopped.
  context "when the ledger refuses a call mid-validation" do
    # The seed's pass, iteration 1 (rejected) and iteration 2 up to its
    # child's minibatch are 174 calls; 40 more reach into its validation.
    let(:admit) { 174 + 40 }
    let(:validation_run) { stopped_run("validation") }

    # An eval run of the stopped iteration, which has no line.
    def stopped_run(role)
      Smith::Evals::Identity.eval_run_id(key: "#{run_id}/2/#{role}", scope: tuning_scope, suite: "spec.tuned_qa")
    end

    def passes(record)
      (eval_runs(record) + %w[parent child validation].map { stopped_run(_1) }).map { eval_record(_1) }
    end

    def ran_lines(records) = records.flat_map { _1.each_trial.reject { |line| line["outcome"] == "not_run" } }

    it "ends stopped_at_limit, that candidate not added, counting no refused trial and starting none after it" do
      record = tuned
      run = eval_record(validation_run)
      counted = ran_lines(passes(record))

      expect(record.summary.values_at("status", "ended", "candidates")).to eq(["stopped", "stopped_at_limit", 1])
      expect(record.summary["stop"]).to eq("code" => "cap_reached", "detail" => "the cap refused calls in a pass")
      expect(record.iterations.map { _1["ended_as"] }).to eq(%w[accepted rejected])
      expect(run.summary["status"]).to eq("incomplete")
      expect(run.each_trial.count).to be <= 11
      expect(record.metric_calls_used).to eq(counted.size)
    end

    # A call the ledger refused was never sent: it costs a known 0, in the
    # eval run's lines and summary and in the tuning run's totals alike.
    it "keeps its cost complete, a refused call costing a known 0" do
      record = tuned
      run = eval_record(validation_run)

      expect(run.each_trial.map { _1.dig("usage", "cost_complete") }.uniq).to eq([true])
      expect(run.summary.dig("usage", "cost_complete")).to be(true)
      expect(record.summary.dig("usage", "cost_complete")).to be(true)
    end

    it "goes on when called again with the cap raised, as a run never stopped would have, running no trial twice" do
      tuned
      ledger.instance_variable_set(:@admit, nil)
      resumed = tuned
      whole = tuned(store: Smith::Evals::Stores::Memory.new)
      scored = eval_runs(resumed).flat_map { eval_record(_1).each_line.select { |line| line["outcome"] == "scored" } }

      expect(TuningRunSuite.steady(resumed.lines)).to eq(TuningRunSuite.steady(whole.lines))
      expect(resumed.summary.values_at("status", "ended", "metric_calls_used", "summary_revision"))
        .to eq(["finished", "proposal", whole.metric_calls_used, 2])
      expect(scored.map { _1["trial_id"] }.tally.values.uniq).to eq([1])
      expect(eval_record(validation_run).summary["summary_revision"]).to eq(2)
    end

    # One trial at a time, the eleventh validation trial's third call is
    # refused: it sent two, so it keeps a not_run line for its spend, and
    # is still no metric call and not in the pass.
    context "when the refused trial had sent a request" do
      let(:admit) { 174 + 42 }

      it "keeps its line for the spend, counting it in neither the metric calls nor the pass" do
        record = tuned(tuning_suite(concurrency: 1))
        refused = eval_record(validation_run).each_trial.select { _1["outcome"] == "not_run" }
        counted = ran_lines(passes(record))

        expect(refused.map { _1["usage"]["provider_calls"] }).to eq([2])
        expect(record.metric_calls_used).to eq(counted.size)
      end
    end
  end

  # Probe R-B of the review: the cap inside the seed's pass. Resumed, the
  # same eval run goes on; no trial it answered is paid for again.
  context "when the ledger refuses a call inside the seed's pass" do
    let(:admit) { 4 * 10 }

    it "resumes the seed's eval run, paying for no trial it answered" do
      first = tuned
      ledger.instance_variable_set(:@admit, nil)
      second = tuned
      seed = second.iterations.first.dig("validation", "eval_run_id")
      answered = eval_record(seed).each_line.select { _1["outcome"] == "scored" }.map { _1["trial_id"] }

      expect(first.summary.values_at("status", "iterations", "metric_calls_used")).to eq(["stopped", 0, 10])
      expect(second.iterations.map { _1["iteration"] }.first(2)).to eq([0, 1])
      expect(answered.tally.values.uniq).to eq([1])
      expect(answered.size).to eq(31)
      expect(second.iterations.first.dig("totals", "metric_calls")).to eq(31)
    end
  end

  context "when a reflection fails on each of its attempts" do
    let(:reflection_setting) { super().merge(attempts: 2) }
    let(:reply) { failing(super(), 2) }

    it "ends that iteration reflection_failed, both attempts recorded, and goes on to improve the prompt" do
      record = tuned
      failed = record.reflections.first

      expect(record.iterations[1]["ended_as"]).to eq("reflection_failed")
      expect(failed["steps"].size).to eq(2)
      expect(failed.values_at("output", "stop")).to eq([nil, nil])
      expect(record.summary.values_at("status", "ended")).to eq(%w[finished proposal])
      expect(record.best.texts["draft.predict"]).to eq(TuningRunSuite::GOOD_DRAFT)
      expect(record.summary.dig("usage", "provider_calls"))
        .to eq(record.reflections.sum { _1["steps"].size } + (record.metric_calls_used * 4))
    end
  end

  # A reflection the cap stopped writes no line: called again, the run asks
  # it again.
  context "when the ledger refuses a reflection's second attempt" do
    # The seed's pass is 124 calls and iteration 1's parent minibatch 12
    # more: its reflection's first attempt is the 137th call, and fails.
    let(:admit) { 137 }
    let(:reflection_setting) { super().merge(attempts: 3) }
    let(:reply) { failing(super(), 1) }

    it "ends stopped_at_limit, asking no third attempt, and asks it again when called again" do
      record = tuned
      ledger.instance_variable_set(:@admit, nil)
      resumed = tuned

      expect(record.summary.values_at("status", "ended")).to eq(%w[stopped stopped_at_limit])
      expect(record.summary["stop"])
        .to eq("code" => "cap_reached", "detail" => "the reflection call stopped: cap_reached")
      expect(record.reflections).to eq([])
      expect(record.summary["usage"].values_at("reflection_calls", "provider_calls")).to eq([1, 124 + 12 + 1])
      expect(resumed.reflections.first.values_at("iteration", "output")).to include(1)
      expect(resumed.summary.values_at("status", "ended")).to eq(%w[finished proposal])
    end
  end

  # A reflection an error that stops every run refused (its key gone) is
  # not written: called again once the key is found, it is asked again.
  context "when the reflection's key goes missing" do
    let(:missing) { [true] }
    let(:reply) do
      answer = super()
      gone = missing
      lambda do |request|
        raise Smith::ProviderCredentialsMissing.new(provider: :openai, model_id: "gpt-4.1-mini") if gone.first

        answer.call(request)
      end
    end

    it "stops the run, writing no reflection line, and asks the reflection again once the key is found" do
      first = tuned
      missing[0] = false
      second = tuned

      expect(first.summary.values_at("status", "ended")).to eq(%w[stopped failed])
      expect(first.summary["stop"]["code"]).to eq("credentials_missing")
      expect(first.reflections).to eq([])
      expect(second.reflections.first.values_at("iteration", "failure")).to eq([1, nil])
      expect(second.summary.values_at("status", "ended")).to eq(%w[finished proposal])
    end
  end

  # Probe R-C of the review: an error that stops every run (a missing key)
  # mid-search stops the tuning run, to go on once the key is found.
  context "when the key goes missing mid-search" do
    let(:missing) { [false] }

    before do
      gone = missing
      find = lambda do |request|
        raise Smith::ProviderCredentialsMissing.new(provider: :openai, model_id: "gpt-4.1-mini") if gone.first

        TuningRunSuite.answer(:spec_tuned_find, request)
      end
      Smith::Testing.stub_agent(:spec_tuned_find, usage: { input_tokens: 100, output_tokens: 20 }, outputs: find)
      calls = 0
      seam = Smith::Tuning::Evaluation::InProcess
      allow_any_instance_of(seam).to receive(:evaluate).and_wrap_original do |evaluate, *args, **options|
        gone[0] = (calls += 1) == 5
        evaluate.call(*args, **options)
      end
    end

    it "stops the run, and finishes it when called again once the key is found" do
      first = tuned
      missing[0] = false
      allow_any_instance_of(Smith::Tuning::Evaluation::InProcess).to receive(:evaluate).and_call_original
      second = tuned

      expect(first.summary.values_at("status", "ended")).to eq(%w[stopped failed])
      expect(first.summary["stop"]["code"]).to eq("credentials_missing")
      expect(second.summary.values_at("status", "ended")).to eq(%w[finished proposal])
      expect(second.metric_calls_used).to eq(tuned(store: Smith::Evals::Stores::Memory.new).metric_calls_used)
    end
  end

  # The wire check reads every trial: a driver that loses the candidate in
  # one trial of the child's validation pass is caught.
  it "stops candidate_not_sent when its driver drops the candidate in one trial only" do
    dropping = Class.new(Smith::Evals::Drivers::InProcess) do
      def run(trial, context) = super(trial.sample.id == "v-020" ? trial.with(candidate: nil) : trial, context)
    end
    suite = tuning_suite
    suite.driver(dropping.new)
    record = tuned(suite)

    expect(record.summary.values_at("status", "ended", "candidates")).to eq(["failed", "failed", 1])
    expect(record.summary["stop"]["code"]).to eq("candidate_not_sent")
  end

  # A subject that runs out of its own limit (here its transitions) in one
  # trial fails that sample, a 0; it is not the cap, and the search goes on.
  it "scores a trial that hit the subject's own limit 0, and goes on" do
    limited = Smith::Evals::Subject.new(workflow: Class.new(SpecTunedQA) { max_transitions 2 },
                                        input: ->(sample) { { question: sample.input } }, keep: %i[answer])
    stub_const("SpecTunedLimited", limited)
    limiting = Class.new(Smith::Evals::Drivers::InProcess) do
      def run(trial, context)
        super(trial.sample.id == "v-003" ? trial.with(subject: SpecTunedLimited) : trial, context)
      end
    end
    suite = tuning_suite
    suite.driver(limiting.new)
    record = tuned(suite)
    seed = eval_record(record.iterations.first.dig("validation", "eval_run_id"))

    limit = seed.each_trial.find { _1["sample_id"] == "v-003" }
    expect([limit["outcome"], limit.dig("reason", "code")]).to eq(%w[limit_hit max_transitions])
    expect(record.iterations.first.dig("validation", "scores", "v-003")).to eq(0.0)
    expect(record.summary.values_at("status", "ended")).to eq(%w[finished proposal])
  end

  # A subject whose calls have no price leaves the run's cost a floor.
  it "says its cost is not complete when a trial's cost is not known" do
    Smith.config.pricing = { %w[openai gpt-4.1-nano] => { input_cost_per_token: 0.000001,
                                                          output_cost_per_token: 0.000004 } }
    setting = reflection_setting.merge(model: "gpt-4.1-nano")
    Smith::Testing.stub_agent(Smith::Tuning::Reflection::Runner.agent(setting),
                              usage: { input_tokens: 400, output_tokens: 60 }, outputs: reply)
    record = tuned(reflection: setting)

    expect(record.reflections.map { _1.dig("usage", "cost_complete") }.uniq).to eq([true])
    expect(record.summary.dig("usage", "cost_complete")).to be(false)
  end

  it "warns feedback_weak only when the objective scorer gives no feedback text" do
    plain = Class.new(Smith::Evals::Scorer) do
      scorer_name :exact
      version 1

      def score(sample, trial) = Smith::Evals::Score.match(trial.state.dig(:answer, :text), sample.expected)
    end

    expect(tuned.summary["warnings"]).to eq([])
    expect(tuned(tuning_suite(scorer: plain), idempotency_key: "tune-2").summary["warnings"]).to eq(["feedback_weak"])
  end

  it "writes every record valid against its schema, open and strict" do
    record = tuned
    runs = eval_runs(record).map { eval_record(_1) }

    expect(valid?(record.header, "tuning-header")).to be(true)
    expect(record.lines.map { valid?(_1, "tuning-line") }).to all(be(true))
    expect(valid?(record.summary, "tuning-summary")).to be(true)
    expect(runs.map { valid?(_1.header, "record-header") }).to all(be(true))
    expect(runs.flat_map { _1.each_trial.to_a }.map { valid?(_1, "trial") }).to all(be(true))
    expect(runs.map { valid?(_1.summary, "summary") }).to all(be(true))
    expect(runs.map { _1.header["kind"] }.tally).to eq("tuning_validation" => 2, "tuning_minibatch" => 13)
  end

  it "gives the same lines for one seed, times and boundaries aside, and other minibatches for another" do
    first = tuned
    again = tuned(store: Smith::Evals::Stores::Memory.new)
    other = tuned(store: Smith::Evals::Stores::Memory.new, seed: 3)
    batches = ->(record) { record.iterations.map { _1.dig("minibatch", "sample_ids") } }

    expect(TuningRunSuite.steady(again.lines)).to eq(TuningRunSuite.steady(first.lines))
    expect(again.lines).not_to eq(first.lines)
    expect(batches.call(other)).not_to eq(batches.call(first))
  end

  it "returns a finished run for its key as it is, running nothing" do
    first = tuned
    Smith::Testing.reset!
    again = tuned

    expect(again.lines).to eq(first.lines)
    expect(again.summary).to eq(first.summary)
  end
end
