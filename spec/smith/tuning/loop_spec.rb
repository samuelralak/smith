# frozen_string_literal: true

require "tmpdir"
require "smith/tuning"

# The loop (slice 5a design, section 1, and section 2's "two forms, one
# loop"), on the specs' stub for the seam: the seed's validation pass, then
# each iteration's pick, rotation, minibatches, reflection, strict
# acceptance and the child's validation pass; the stop rules checked before
# each iteration; and a loop opened again on its record, which continues as
# the first would have.
RSpec.describe Smith::Tuning::Loop do
  around do |example|
    Dir.mktmpdir("smith-tuning-loop") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:store) { Smith::Evals::Stores::Memory.new }
  let(:suite) { TuningRecords.suite(File.join(@dir, "data"), workflow) }
  let(:run_id) { Smith::Evals::Identity.tuning_run_id(key: "k", scope: {}, suite: "tuning.demo") }
  let(:validation_ids) { TuningRecords.validation_ids }
  let(:reflection) { { model: "gpt-4.1-mini", provider: :openai } }
  # A text the reflection made better scores 0.5 more, to at most 1.
  let(:score) { ->(candidate, _id) { [candidate.texts.values.count { _1.end_with?("better.") } * 0.5, 1.0].min } }
  let(:reply) { ->(message) { { idea: "Better.", instruction: "#{TuningRunSuite.current(message)} Do it better." } } }
  let(:stub) { TuningTrialsStub.new(score:, reply:) }

  let(:workflow) do
    names = TuningRecords.prompts.to_h do |id, prompt|
      name = :"spec_loop_#{id.split(".").first}"
      agent = Class.new(Smith::Agent) do
        model "gpt-4.1-mini", provider: :openai, assume_model_exists: true
        instructions prompt
      end
      stub_const("SpecLoop#{id.split(".").first.capitalize}", agent)
      Smith::Agent::Registry.delete(name)
      agent.register_as(name)
      [id, name]
    end
    with_stubbed_class("SpecLoopFlow", Smith::Workflow) do
      initial_state :asked
      %i[summarized answered].each { state _1 }
      transition(:summarize, from: :asked, to: :summarized) { execute names["summarize.predict"] }
      transition(:answer, from: :summarized, to: :answered) { execute names["answer.predict"] }
    end
  end

  def settings(**overrides)
    Smith::Tuning::Settings.new(objective: :exact_match, components: %w[summarize.predict answer.predict],
                                split: { train: { tags_any: ["train"] }, validation: { tags_any: ["val"] } },
                                reflection:, stop: { max_metric_calls: 110, rounds_without_improvement: nil },
                                **overrides)
  end

  def opened(trials: stub, store: self.store, **overrides)
    described_class.open(suite, settings: settings(**overrides), scope: {}, store:, idempotency_key: "k",
                                started_by: nil, trials:)
  end

  # At most 200 iterations, so a loop that never stops fails here (finish!
  # refuses a run that has not stopped) rather than hanging.
  def ran(loop = opened)
    200.times do
      break if loop.done?

      loop.iterate!
    end
    loop.finish!
  end

  def lines(store = self.store) = store.each_tuning_line(scope: {}, tuning_run_id: run_id).to_a
  def iterations(store = self.store) = lines(store).select { _1["type"] == "iteration" }
  def asked(trials = stub) = trials.evaluations.map { [_1[:kind], _1[:key].split("/", 2).last, _1[:component]] }

  describe "an iteration" do
    it "scores the seed on validation, then picks a parent, rotates its components and runs both minibatches" do
      record = ran

      expect(asked.first(8)).to eq([[:tuning_validation, "0/seed", nil],
                                    [:tuning_minibatch, "1/parent", "summarize.predict"],
                                    [:tuning_minibatch, "1/child", nil], [:tuning_validation, "1/validation", nil],
                                    [:tuning_minibatch, "2/parent", "answer.predict"],
                                    [:tuning_minibatch, "2/child", nil], [:tuning_validation, "2/validation", nil],
                                    [:tuning_minibatch, "3/parent", "summarize.predict"]])
      expect(stub.evaluations.first[:sample_ids]).to eq(validation_ids)
      expect(stub.evaluations.drop(1).select { _1[:kind] == :tuning_minibatch }.flat_map { _1[:sample_ids] })
        .to all(start_with("t-"))
      expect(iterations.map { _1["ended_as"] })
        .to eq(%w[accepted accepted accepted perfect_minibatch perfect_minibatch])
      expect(record.candidates.map { [_1.index, _1.parent, _1.mean] }).to eq([[0, nil, 0.0], [1, 0, 0.5], [2, 1, 1.0]])
      expect(record.best.texts.values).to all(end_with("Do it better."))
      expect(record.summary.values_at("seed", "best"))
        .to eq([{ "candidate_id" => record.candidates[0].candidate_id, "index" => 0, "mean" => 0.0 },
                { "candidate_id" => record.candidates[2].candidate_id, "index" => 2, "mean" => 1.0 }])
    end

    it "uses one minibatch for the parent and the child, and draws the next ones epoch by epoch" do
      ran
      batches = stub.evaluations.select { _1[:kind] == :tuning_minibatch }.map { _1[:sample_ids] }

      expect(batches[0]).to eq(batches[1])
      expect(iterations.drop(1).map { _1.dig("minibatch", "sample_ids") }.first(4).flatten.uniq.size).to eq(12)
    end

    context "when the child's minibatch mean only equals its parent's" do
      let(:reply) { ->(message) { { idea: "Same.", instruction: "#{TuningRunSuite.current(message)} Again." } } }

      it "rejects it, and scores no validation pass for it" do
        ran(opened(stop: { max_metric_calls: 50, rounds_without_improvement: nil }))

        expect(iterations.drop(1).map { _1["ended_as"] }).to all(eq("rejected"))
        expect(stub.evaluations.count { _1[:kind] == :tuning_validation }).to eq(1)
        expect(iterations.drop(1).map { _1.dig("child", "index") }).to all(be_nil)
      end
    end

    context "when the parent scores perfect_score on every minibatch sample" do
      let(:score) { ->(*) { 1.0 } }

      it "ends with no reflection, unless the setting is off" do
        ran(opened(stop: { max_metric_calls: 40, rounds_without_improvement: nil }))
        skipped = stub.reflections.size
        other = TuningTrialsStub.new(score:, reply:)
        ran(opened(trials: other, store: Smith::Evals::Stores::Memory.new, skip_perfect: false,
                   stop: { max_metric_calls: 40, rounds_without_improvement: nil }))

        expect(skipped).to eq(0)
        expect(iterations.drop(1).map { _1["ended_as"] }).to all(eq("perfect_minibatch"))
        expect(other.reflections.size).to be_positive
      end
    end

    context "when the reflection's text changes the component's fill-in fields" do
      let(:reply) { ->(_message) { { idea: "Name it.", instruction: "Answer {{question}}." } } }

      it "ends the iteration proposal_invalid, with no child run" do
        ran(opened(stop: { max_metric_calls: 40, rounds_without_improvement: nil }))

        expect(iterations.drop(1).map { _1["ended_as"] }).to all(eq("proposal_invalid"))
        expect(stub.evaluations.map { _1[:key] }).not_to include(end_with("/child"))
      end
    end

    context "when the reflection fails" do
      let(:reply) { ->(_message) { raise IOError, "the model broke" } }

      it "ends only its iteration, and the run goes on" do
        record = ran(opened(stop: { max_metric_calls: 40, rounds_without_improvement: nil }))

        expect(iterations.drop(1).map { _1["ended_as"] }).to all(eq("reflection_failed"))
        expect(iterations.size).to be > 2
        expect(record.status).to eq(:finished)
      end
    end
  end

  describe "the stop rules" do
    it "starts no iteration once metric calls reach the limit, and passes it by at most 2b + n_val" do
      record = ran

      used = iterations.map { _1.dig("totals", "metric_calls") }
      expect(used).to eq([31, 68, 105, 108, 111])
      expect(used[-2]).to be < 110
      expect(record.metric_calls_used).to eq(111).and(be < 110 + (2 * 3) + 31)
      expect(record.metric_calls_used).to eq(stub.evaluations.sum { _1[:sample_ids].size })
      expect(record.summary.values_at("status", "ended", "stop"))
        .to eq(["finished", "proposal", { "code" => "metric_calls", "detail" => "111 of 110 metric calls used" }])
    end

    it "starts no iteration when the metric calls used equal the limit" do
      record = ran(opened(stop: { max_metric_calls: 108, rounds_without_improvement: nil }))

      expect(record.summary.values_at("metric_calls_used", "iterations")).to eq([108, 4])
    end

    # The reserve: 2b + n_val metric calls at the run's mean cost and its
    # costliest reflection, times 1.25. After the seed, 31 calls of 100
    # nanos: 3,100 spent and a reserve of 1.25 * 37 * 100 = 4,625.
    it "stops on dollars when what is spent and one iteration's reserve would pass the limit" do
      stopped = ran(opened(stop: { max_cost_nanos: 7_724, rounds_without_improvement: nil }))
      going = ran(opened(store: Smith::Evals::Stores::Memory.new, trials: TuningTrialsStub.new(score:, reply:),
                         stop: { max_cost_nanos: 7_725, rounds_without_improvement: nil }))

      expect(stopped.summary.values_at("iterations", "stop"))
        .to eq([1, { "code" => "cost", "detail" => "3100 nanos spent and 4625 kept for one more iteration" }])
      expect(going.summary["iterations"]).to be > 1
    end

    # After iteration 1 (kept): 68 calls and a reflection of 1,200 nanos,
    # 8,000 spent; the mean is the subject's alone (100), so the reserve is
    # 1.25 * (37 * 100 + 1,200) = 6,125.
    it "reads the subject's mean cost and the costliest reflection into the reserve" do
      stopped = ran(opened(stop: { max_cost_nanos: 14_124, rounds_without_improvement: nil }))
      going = ran(opened(store: Smith::Evals::Stores::Memory.new, trials: TuningTrialsStub.new(score:, reply:),
                         stop: { max_cost_nanos: 14_125, rounds_without_improvement: nil }))

      expect(stopped.summary.values_at("iterations", "stop"))
        .to eq([2, { "code" => "cost", "detail" => "8000 nanos spent and 6125 kept for one more iteration" }])
      expect(going.summary["iterations"]).to be > 2
    end

    # A cap stop writes no line for its iteration: called again (the cap
    # raised), the run replays it under the same keys, and goes on as a
    # run never stopped would have.
    context "when the ledger refuses a call inside a pass" do
      let(:stub) { TuningTrialsStub.new(score:, reply:, admit: 31 + 3 + 1 + 3 + 10) }

      def without_steps(lines) = lines.map { _1["type"] == "reflection" ? _1.except("steps") : _1 }

      it "ends stopped_at_limit, its iteration replayed when called again as an unstopped run's" do
        record = ran
        stopped_lines = lines
        again = TuningTrialsStub.new(score:, reply:)
        ran(opened(trials: again))
        whole = Smith::Evals::Stores::Memory.new
        ran(opened(store: whole, trials: TuningTrialsStub.new(score:, reply:)))
        stored_reflection = Smith::Evals::Identity.reflection_trial_id(tuning_run_id: run_id, iteration: 1)

        expect(record.summary.values_at("status", "ended", "candidates", "iterations"))
          .to eq(["stopped", "stopped_at_limit", 1, 1])
        expect(record.summary["stop"]).to eq("code" => "cap_reached", "detail" => "the cap refused calls in a pass")
        expect(stopped_lines.map { _1.values_at("type", "iteration") }).to eq([["iteration", 0], ["reflection", 1]])
        expect(again.evaluations.first[:key]).to eq("#{run_id}/1/parent")
        expect(again.reflections.map { _1[:trial_id] }).not_to include(stored_reflection)
        expect(without_steps(lines)).to eq(without_steps(lines(whole)))
      end
    end

    # A check a pass fails, or an error of the subject's that every trial
    # would meet, ends the run for good: the stop is in the iteration's
    # line, so the loop stops at once, and a run opened again is returned
    # as it is.
    %i[candidate_not_sent scorer_failed definition_error scope_conflict].each do |code|
      context "when a pass stops at #{code}" do
        let(:stub) do
          TuningTrialsStub.new(score:, reply:).tap do |trials|
            trials.define_singleton_method(:evaluate) do |candidate, **options|
              pass = super(candidate, **options)
              options[:key].end_with?("/1/child") ? pass.with(stop: code) : pass
            end
          end
        end

        it "ends failed, the stop in the iteration's line, and stays so" do
          record = ran
          again = TuningTrialsStub.new(score:, reply:)
          ran(opened(trials: again))

          expect(record.summary.values_at("status", "ended", "iterations")).to eq(["failed", "failed", 2])
          expect(iterations.last.values_at("iteration", "ended_as")).to eq([1, "incomplete"])
          expect(iterations.last.dig("stop", "code")).to eq(code.to_s)
          expect(again.evaluations).to be_empty
        end
      end
    end

    # A reflection retried after an attempt the provider billed and then
    # failed: its cost is every attempt's, in the totals and the reserve.
    it "counts every attempt of a reflection in the run's cost" do
      trials = TuningTrialsStub.new(score:, reply:)
      trials.define_singleton_method(:reflect) do |message, trial_id:|
        call = super(message, trial_id:)
        billed = call.steps.first.merge("outcome" => "failed", "cost_nanos" => 800)
        usage = Smith::Evals::Spend.new.add_usage(call.usage)
                                   .add(provider: "openai", model: "gpt-4.1-mini", provider_calls: 1, tokens: nil,
                                        cost_nanos: 800, cost_complete: true).usage
        call.with(steps: [billed, *call.steps], usage:)
      end
      record = ran(opened(trials:, stop: { max_metric_calls: 40, rounds_without_improvement: nil }))
      usage = record.summary["usage"]

      expect(usage["reflection_calls"]).to be_positive
      expect(usage["cost_nanos"]).to eq((record.metric_calls_used * 100) + (usage["reflection_calls"] * 2_000))
      expect(usage["provider_calls"]).to eq(record.metric_calls_used + (usage["reflection_calls"] * 2))
    end

    it "reads the cancel flag before the budget rules" do
      loop = opened(stop: { max_metric_calls: 31, rounds_without_improvement: nil })
      loop.iterate!
      Smith::Tuning.cancel(run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: "wrong split", scope: {},
                                   store:)

      expect(ran(loop).summary.values_at("status", "stop"))
        .to eq(["cancelled", { "code" => "cancelled", "detail" => "wrong split" }])
    end

    it "stops at max_candidates, at the deadline and on cancel, before the next iteration" do
      by_candidates = ran(opened(stop: { max_metric_calls: 1_000, max_candidates: 2, rounds_without_improvement: nil }))
      store = Smith::Evals::Stores::Memory.new
      by_deadline = ran(opened(store:, trials: TuningTrialsStub.new(score:, reply:),
                               stop: { deadline: Time.now - 1, rounds_without_improvement: nil }))
      cancelled_store = Smith::Evals::Stores::Memory.new
      loop = opened(store: cancelled_store, trials: TuningTrialsStub.new(score:, reply:))
      loop.iterate!
      Smith::Tuning.cancel(run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: "wrong split", scope: {},
                                   store: cancelled_store)
      cancelled = ran(loop)

      expect(by_candidates.summary.values_at("candidates", "stop"))
        .to eq([2, { "code" => "candidates", "detail" => "2 candidates" }])
      expect(by_deadline.summary.values_at("iterations", "candidates", "best")).to eq([0, 0, nil])
      expect(by_deadline.summary["stop"]["code"]).to eq("deadline")
      expect(cancelled.summary.values_at("status", "ended", "iterations", "stop"))
        .to eq(["cancelled", "cancelled", 1, { "code" => "cancelled", "detail" => "wrong split" }])
    end

    context "when no child does better" do
      let(:score) { ->(*) { 0.0 } }

      it "stops after the set number of rounds without improvement, and never when it is off" do
        rounds = ran(opened(stop: { max_metric_calls: 200, rounds_without_improvement: 3 }))
        off = ran(opened(store: Smith::Evals::Stores::Memory.new, trials: TuningTrialsStub.new(score:, reply:),
                         stop: { max_metric_calls: 70, rounds_without_improvement: nil }))

        expect(rounds.summary.values_at("iterations", "stop", "ended"))
          .to eq([4, { "code" => "no_improvement", "detail" => "3 iterations without a better candidate" },
                  "nothing_better"])
        expect(off.summary["stop"]["code"]).to eq("metric_calls")
      end
    end

    it "counts rounds without improvement from the last time the best rose" do
      record = ran(opened(stop: { max_metric_calls: 200, rounds_without_improvement: 2 }))

      expect(iterations.map { _1["ended_as"] })
        .to eq(%w[accepted accepted accepted perfect_minibatch perfect_minibatch])
      expect(record.summary["stop"]["code"]).to eq("no_improvement")
    end
  end

  describe "opened again on its record" do
    # The stub stops the process at a call: an error no loop rescues, as a
    # kill does, after the given number of evaluations or reflections.
    def failing(after:, on: :evaluate)
      count = 0
      stub = TuningTrialsStub.new(score:, reply:)
      stub.define_singleton_method(on) do |*args, **kwargs|
        count += 1
        raise NoMemoryError, "killed" if count > after

        super(*args, **kwargs)
      end
      stub
    end

    # The killed process's lease ends with it.
    def interrupted(store, after:, on: :evaluate)
      loop = opened(store:, trials: failing(after:, on:))
      expect { ran(loop) }.to raise_error(NoMemoryError)
      loop.close
      lines(store).size
    end

    let(:whole) do
      other = Smith::Evals::Stores::Memory.new
      ran(opened(store: other, trials: TuningTrialsStub.new(score:, reply:)))
      lines(other)
    end

    def without_steps(lines) = lines.map { _1["type"] == "reflection" ? _1.except("steps") : _1 }

    # Killed: after iteration 1's reflection line, before its child's
    # minibatch; at its validation pass; at iteration 2's reflection; at
    # iteration 2's child.
    it "continues as the first would have, killed after a reflection line or mid-iteration" do
      [[2, :evaluate], [3, :evaluate], [1, :reflect], [5, :evaluate]].each do |after, on|
        store = Smith::Evals::Stores::Memory.new
        kept = interrupted(store, after:, on:)
        resumed = TuningTrialsStub.new(score:, reply:)
        ran(opened(store:, trials: resumed))

        expect(without_steps(lines(store))).to eq(without_steps(whole)), "killed after #{on} #{after}"
        expect(kept).to be_positive
        stored = lines(store).first(kept).select { _1["type"] == "reflection" }.map { _1["iteration"] }
        asked_again = resumed.reflections.map { _1[:trial_id] } &
                      stored.map { Smith::Evals::Identity.reflection_trial_id(tuning_run_id: run_id, iteration: _1) }
        expect(asked_again).to eq([])
      end
    end

    # DSPy's run, read from its dry run's log (which candidate each new one
    # came from and which component it changed): a skipped perfect
    # minibatch leaves the parent's rotation where it was.
    context "when a minibatch is perfect" do
      let(:batch) do
        other = Smith::Evals::Stores::Memory.new
        ran(opened(store: other, trials: TuningTrialsStub.new(score: ->(*) { 0.0 }, reply:)))
        iterations(other)[1].dig("minibatch", "sample_ids")
      end
      let(:score) { ->(_candidate, id) { batch.include?(id) ? 1.0 : 0.0 } }

      it "rewrites next the component the skipped iteration would have, live and restored" do
        ran(opened(trials: TuningTrialsStub.new(score:, reply:)))
        killed = Smith::Evals::Stores::Memory.new
        interrupted(killed, after: 4)
        ran(opened(store: killed, trials: TuningTrialsStub.new(score:, reply:)))

        expect(iterations.drop(1).first(3).map { _1.values_at("ended_as", "component") })
          .to eq([%w[perfect_minibatch summarize.predict], %w[rejected summarize.predict], %w[rejected answer.predict]])
        expect(without_steps(lines(killed))).to eq(without_steps(lines))
      end

      it "counts a minibatch perfect only when every score is" do
        ran(opened(trials: TuningTrialsStub.new(score: ->(_candidate, id) { batch.first(2).include?(id) ? 1.0 : 0.0 },
                                                reply:)))

        expect(iterations[1].values_at("ended_as", "component")).to eq(%w[rejected summarize.predict])
      end
    end

    # The reserve after a kill and resume: a stored reflection is read into
    # it once, so the run stops where an uninterrupted one does, after
    # iteration 1. Killed at iteration 1's child, after its reflection line.
    it "keeps the dollar stop's reserve across a kill and resume" do
      budget = { max_cost_nanos: 14_124, rounds_without_improvement: nil }
      whole = ran(opened(store: Smith::Evals::Stores::Memory.new, trials: TuningTrialsStub.new(score:, reply:),
                         stop: budget))
      killed = Smith::Evals::Stores::Memory.new
      loop = opened(store: killed, trials: failing(after: 2), stop: budget)
      expect { ran(loop) }.to raise_error(NoMemoryError)
      loop.close
      resumed = ran(opened(store: killed, trials: TuningTrialsStub.new(score:, reply:), stop: budget))

      expect(resumed.summary["stop"]["code"]).to eq("cost")
      expect(resumed.summary.values_at("iterations", "stop")).to eq(whole.summary.values_at("iterations", "stop"))
    end

    it "refuses a changed setting, naming it" do
      ran

      expect { opened(seed: 1) }.to raise_error(Smith::Evals::ResumeMismatch) { expect(_1.fields).to eq(["settings"]) }
    end

    it "returns a finished run as it is, and resumes one the cap stopped" do
      capped = TuningTrialsStub.new(score:, reply:, admit: 40)
      stopped = ran(opened(trials: capped))
      again = TuningTrialsStub.new(score:, reply:)
      resumed = ran(opened(trials: again))
      returned = TuningTrialsStub.new(score:, reply:)
      ran(opened(trials: returned))

      expect(stopped.status).to eq(:stopped)
      expect([resumed.status, resumed.summary["summary_revision"]]).to eq([:finished, 2])
      expect(again.evaluations).not_to be_empty
      expect(returned.evaluations).to be_empty
    end
  end

  it "gives the same lines for one seed, and other minibatches for another" do
    first = ran
    second_store = Smith::Evals::Stores::Memory.new
    ran(opened(store: second_store, trials: TuningTrialsStub.new(score:, reply:)))
    other_store = Smith::Evals::Stores::Memory.new
    ran(opened(store: other_store, trials: TuningTrialsStub.new(score:, reply:), seed: 7))
    batches = ->(lines) { lines.select { _1["type"] == "iteration" }.map { _1.dig("minibatch", "sample_ids") } }

    unbounded = ->(lines) { JSON.generate(lines).gsub(/boundary=\\"[0-9a-f]+\\"/, "boundary") }
    expect(unbounded.call(lines(second_store))).to eq(unbounded.call(lines))
    expect(JSON.generate(lines)).to include("boundary=")
    expect(first.candidates.map(&:texts)).to eq(Smith::Tuning.record(run_id, scope: {}, store: second_store)
                                                               .candidates.map(&:texts))
    expect(batches.call(lines(other_store))).not_to eq(batches.call(lines))
  end
end
