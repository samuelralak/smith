# frozen_string_literal: true

require "tmpdir"
require "smith/tuning"

# The tuning record at format version 0 (slice 5a design, section 3): the
# header, an iteration line for each way an iteration ends, a reflection
# line, the summary, each valid against its schema as published and
# strict; the tuning digest, which ignores ids, times and actors and
# nothing else; and the reader, which rebuilds each candidate from the
# lines.
RSpec.describe Smith::Tuning::Record do
  around do |example|
    Dir.mktmpdir("smith-tuning-record") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:workflow) { stub_const("TuningSpecFlow", Class.new(Smith::Workflow)) }
  let(:suite) { TuningRecords.suite(File.join(@dir, "data"), workflow) }
  let(:selection) { suite.selection }
  let(:run) { Smith::Evals::Identity.tuning_run_id(key: "pilot-s0", scope: {}, suite: "tuning.demo") }
  let(:split_setting) { { train: { tags_any: ["train"] }, validation: { tags_any: ["val"] } } }
  let(:reflection) do
    { model: "gpt-4.1-mini-2025-04-14", provider: :openai, temperature: 1.0, max_output_tokens: 16_384 }
  end
  let(:settings) { Smith::Tuning::Settings.new(objective: :exact_match, split: split_setting, reflection:) }
  let(:at) { Time.utc(2026, 11, 26, 10, 0, 0) }
  let(:split) { Smith::Tuning::Split.given(selection.samples, **settings.split, at:) }
  let(:seed) { Smith::Tuning::Candidate.seed(TuningRecords.prompts, components: nil, tuning_run_id: run) }
  let(:rng) { Smith::Evals::Statistics::SplitMix64.new(0) }
  let(:totals) { { metric_calls: 31, provider_calls: 33, cost_nanos: 9_000, cost_complete: true, reflection_calls: 0 } }

  def header(settings: self.settings, split: self.split, **overrides)
    described_class.header(tuning_run_id: run, scope: {}, created_at: at, started_by: Smith::Evals::Actor.person("u"),
                           idempotency_key: "pilot-s0", selection:, settings:, split:, seed:,
                           host_code_version: "abc123", **overrides)
  end

  def pass(ids, score = 1.0, number: 1, complete: true)
    samples = ids.to_h { [_1, Smith::Tuning::Evaluation::Sample.new(score:, feedback: nil, steps: nil)] }
    Smith::Tuning::Evaluation::Pass.new(eval_run_id: format("er_%032x", number), samples:, metric_calls: samples.size,
                                        provider_calls: samples.size, cost_nanos: 100, cost_complete: true, complete:,
                                        stop: nil)
  end

  def valid!(record, schema)
    %i[open strict].each do |mode|
      expect(EvalsSchema.errors(record, schema:, strict: mode == :strict)).to eq([]), "#{schema} (#{mode})"
    end
  end

  def seed_line
    described_class.iteration(tuning_run_id: run, iteration: 0, ended_as: :accepted, totals:, rng:, cursor: cursor,
                              child: { candidate: seed, index: 0, minibatch: nil },
                              validation: pass(TuningRecords.validation_ids, 0.5))
  end

  def cursor = { "epoch" => 0, "position" => 3 }

  describe "the header" do
    it "holds what is tuned, against what, and with which settings, valid as published and strict" do
      built = header

      expect(built.values_at("format", "format_version", "tuning_run_id", "idempotency_key"))
        .to eq(["smith.tuning.header", 0, run, "pilot-s0"])
      expect(built["suite"]).to eq("name" => "tuning.demo", "version" => selection.manifest["version"],
                                   "measure_digest" => selection.measure_digest)
      expect(built["dataset"]).to eq("name" => "tuning-demo", "version" => selection.dataset.version)
      expect(built["subject"]).to eq("workflow" => "TuningSpecFlow")
      expect(built["objective"]).to eq("scorer" => "exact_match", "scorer_version" => 2, "reveals_expected" => false)
      expect(built["components"]).to eq(seed.prompts.values.map do |prompt|
        { "id" => prompt.component_id, "base_version" => prompt.version, "base_text" => prompt.text }
      end)
      expect(built["split"]).to eq(split.to_h)
      expect(built["settings"]).to eq(settings.to_h)
      expect(built["environment"]).to eq("smith_version" => Smith::VERSION, "host_code_version" => "abc123")
      expect(built["tuning_digest"]).to eq(described_class.digest(built))
      valid!(built, "tuning-header")
    end

    # The owner's ruling on Q4: the scorer's opt-in to feedback naming the
    # expected answer is recorded, and a run resumes only under the same one.
    it "records the scorer's opt-in to naming the expected answer, in the digest" do
      revealing = header(reveals_expected: true)

      expect(revealing.dig("objective", "reveals_expected")).to be(true)
      expect(revealing["tuning_digest"]).not_to eq(header["tuning_digest"])
      valid!(revealing, "tuning-header")
    end

    # The deadline is an absolute time and a setting: a resume passes the
    # header's, not a new one worked out from the clock.
    it "takes the deadline into the digest, as a setting" do
      at_deadline = lambda do |deadline|
        header(settings: Smith::Tuning::Settings.new(objective: :exact_match, split: split_setting, reflection:,
                                                     stop: { deadline: }))["tuning_digest"]
      end

      expect(at_deadline.call(Time.utc(2026, 11, 28))).not_to eq(at_deadline.call(Time.utc(2026, 11, 29)))
    end

    it "refuses an objective the suite does not score" do
      other = Smith::Tuning::Settings.new(objective: :f1, split: split_setting, reflection:)

      expect { header(settings: other) }.to raise_error(ArgumentError, /objective names f1/)
    end

    # A restart with any setting changed is refused on this digest; ids,
    # times and who started it or allowed a small split are not settings.
    it "keeps its digest across ids, times and actors, and changes it with any setting" do
      actor = Smith::Evals::Actor.person("usr_1")
      overridden = lambda do |reason, by, time|
        Smith::Tuning::Split.given(selection.samples, **settings.split, override: { actor: by, reason: }, at: time)
      end
      digest = ->(built) { built["tuning_digest"] }
      same = [header(tuning_run_id: run.sub(/.$/, "0"), idempotency_key: "other", scope: { tenant: "t" },
                     created_at: at + 60, started_by: nil)]
      base = digest.call(header)
      expect(same.map(&digest)).to all(eq(base))
      expect(digest.call(header(split: overridden.call("small", actor, at))))
        .to eq(digest.call(header(split: overridden.call("small", Smith::Evals::Actor.person("usr_2"), at + 5))))

      reordered = Smith::Tuning::Candidate.seed(TuningRecords.prompts, components: TuningRecords.prompts.keys.reverse,
                                                                       tuning_run_id: run)
      changed = [
        header(settings: Smith::Tuning::Settings.new(objective: :exact_match, split: split_setting, reflection:,
                                                     minibatch: 4)),
        header(settings: Smith::Tuning::Settings.new(objective: :exact_match, split: split_setting, reflection:,
                                                     seed: 1)),
        header(settings: Smith::Tuning::Settings.new(objective: :exact_match, split: split_setting, reflection:,
                                                     stop: { max_metric_calls: 10 })),
        header(settings: Smith::Tuning::Settings.new(objective: :exact_match, split: split_setting,
                                                     reflection: reflection.merge(model: "gpt-5"))),
        header(split: Smith::Tuning::Split.given(selection.samples, validation: settings.split[:validation],
                                                                    train: { ids: TuningRecords.train_ids.first(10) },
                                                                    override: nil, at:)),
        header(split: overridden.call("small", actor, at)),
        header(seed: reordered),
        header(host_code_version: "def456")
      ]
      expect(changed.map(&digest)).to all(satisfy { _1 != base })
      expect(changed.map(&digest).uniq.size).to eq(changed.size)
    end
  end

  describe "the lines" do
    let(:child) do
      seed.child("answer.predict", "Answer in one short phrase.", iteration: 1, parent: 0, idea: "Be brief.")
    end
    let(:batch) { TuningRecords.train_ids.first(3) }

    def iteration(ended_as, **parts)
      described_class.iteration(tuning_run_id: run, iteration: 1, ended_as:, totals:, rng:, cursor:,
                                parent: [seed, 0], component: "answer.predict",
                                minibatch: [batch, pass(batch, 0.0, number: 2)], **parts)
    end

    it "writes the seed's line and a line for each way an iteration ends, each valid as published and strict" do
      lines = [
        seed_line,
        iteration(:accepted, child: { candidate: child, index: 1, minibatch: pass(batch, 1.0, number: 3) },
                             validation: pass(TuningRecords.validation_ids, 0.75, number: 4)),
        iteration(:rejected, child: { candidate: child, index: nil, minibatch: pass(batch, 0.0, number: 3) }),
        iteration(:perfect_minibatch), iteration(:proposal_invalid), iteration(:reflection_failed),
        iteration(:incomplete, minibatch: [batch, pass(batch.first(1), number: 2, complete: false)]),
        iteration(:incomplete, child: { candidate: child, index: nil, minibatch: pass([], number: 3, complete: false) },
                               stop: { code: :cap_reached, detail: "the budget ledger refused a call" })
      ]

      lines.each { valid!(_1, "tuning-line") }
      expect(lines.first.values_at("iteration", "parent", "component", "minibatch", "ended_as"))
        .to eq([0, nil, nil, nil, "accepted"])
      expect(lines.first["child"]).to eq("candidate_id" => seed.candidate_id, "index" => 0, "component" => nil,
                                         "version" => nil, "text" => nil, "idea" => nil, "minibatch" => nil)
      expect(lines.first["validation"]).to include("mean" => 0.5, "n" => 31)
      expect(lines[1]["child"]).to include("index" => 1, "component" => "answer.predict",
                                           "text" => "Answer in one short phrase.", "idea" => "Be brief.",
                                           "version" => child.versions["answer.predict"])
      expect(lines[1].values_at("rng", "cursor", "totals"))
        .to eq([rng.to_hex, cursor, { "metric_calls" => 31, "provider_calls" => 33, "cost_nanos" => 9_000,
                                      "cost_complete" => true, "reflection_calls" => 0 }])
      expect(lines[1]["minibatch"]).to eq("sample_ids" => batch, "eval_run_id" => format("er_%032x", 2),
                                          "scores" => batch.to_h { [_1, 0.0] }, "mean" => 0.0)
      expect(lines.last.dig("child", "minibatch")).to include("scores" => {}, "mean" => nil)
      expect(lines.map { _1["stop"] })
        .to eq(([nil] * 7) + [{ "code" => "cap_reached", "detail" => "the budget ledger refused a call" }])
    end

    it "writes a reflection's reply, or its failure, valid as published and strict" do
      trial_id = Smith::Evals::Identity.reflection_trial_id(tuning_run_id: run, iteration: 1)
      step = TuningRecords.step(components: [{ "id" => "smith.tuning.reflect",
                                               "version" => Smith::Tuning::Reflection::PROMPT.version }])
      usage = Smith::Evals::Spend.new.add(provider: "openai", model: "gpt-4.1-mini", provider_calls: 1,
                                          tokens: step["tokens"], cost_nanos: 1_200, cost_complete: true).usage
      call = lambda do |**parts|
        Smith::Tuning::Reflection::Call.new(trial_id:, steps: [step], usage:, output: nil, failure: nil, stop: nil,
                                            **parts)
      end
      failure = { "kind" => "transport", "error_class" => "Faraday::TimeoutError", "message" => "timed out" }
      output = { idea: "Be brief.", instruction: "Answer briefly." }
      replied = described_class.reflection(tuning_run_id: run, iteration: 1, call: call.call(output:))
      failed = described_class.reflection(tuning_run_id: run, iteration: 2,
                                          call: call.call(steps: [], usage: Smith::Evals::Spend.new.usage, failure:,
                                                          stop: :cap_reached))
      garbled = described_class.reflection(tuning_run_id: run, iteration: 3, call: call.call(output: { "idea" => 1 }))

      [replied, failed, garbled].each { valid!(_1, "tuning-line") }
      expect(replied.values_at("type", "trial_id", "output", "failure", "stop"))
        .to eq(["reflection", trial_id, { "idea" => "Be brief.", "instruction" => "Answer briefly." }, nil, nil])
      expect(replied.values_at("steps", "usage")).to eq([[step], usage])
      expect(failed.values_at("steps", "output", "failure", "stop")).to eq([[], nil, failure, "cap_reached"])
      expect(garbled.values_at("output", "failure")).to eq([nil, described_class::REPLY_INVALID])
    end
  end

  describe "the summary" do
    it "is valid as published and strict, running and finished" do
      common = { tuning_run_id: run, scope: {}, iterations: 3, candidates: 2, metric_calls_used: 77,
                 validation_passes: 2, usage: { cost_nanos: 9_000, cost_complete: true, provider_calls: 80,
                                                reflection_calls: 2 } }
      running = described_class.summary(**common, revision: 1, status: :running, ended: nil, stop: nil, seed: nil,
                                                  best: nil)
      finished = described_class.summary(**common, revision: 2, status: :stopped, ended: :stopped_at_limit,
                                                   stop: { code: :metric_calls, detail: nil }, seed: [seed, 0, 0.5],
                                                   best: [seed, 0, 0.5], warnings: [:feedback_weak])

      [running, finished].each { valid!(_1, "tuning-summary") }
      expect(finished.values_at("status", "ended", "stop", "seed", "warnings", "proposal"))
        .to eq(["stopped", "stopped_at_limit", { "code" => "metric_calls", "detail" => nil },
                { "candidate_id" => seed.candidate_id, "index" => 0, "mean" => 0.5 }, ["feedback_weak"], nil])
    end
  end

  describe "reading" do
    it "rebuilds each candidate that joined the pool from the lines: texts, versions, scores, discovery" do
      one = seed.child("answer.predict", "Answer briefly.", iteration: 1, parent: 0)
      lost = seed.child("summarize.predict", "Never kept.", iteration: 2, parent: 0)
      two = one.child("summarize.predict", "Summarize in three lines.", iteration: 3, parent: 1)
      line = lambda do |iteration, candidate, index, metric_calls, parent|
        described_class.iteration(tuning_run_id: run, iteration:, ended_as: index ? :accepted : :rejected,
                                  totals: totals.merge(metric_calls:), rng:, cursor:, parent:,
                                  component: candidate.component,
                                  child: { candidate:, index:, minibatch: nil },
                                  validation: index && pass(TuningRecords.validation_ids, index * 0.25, number: index))
      end
      lines = [line.call(3, two, 2, 99, [one, 1]), seed_line, line.call(2, lost, nil, 60, [seed, 0]),
               line.call(1, one, 1, 40, [seed, 0])]
      record = described_class.new(header: header, lines:, summary: nil)

      candidates = record.candidates
      expect(candidates.map(&:index)).to eq([0, 1, 2])
      expect(candidates.map(&:parent)).to eq([nil, 0, 1])
      expect(candidates.map(&:texts)).to eq([seed.texts, one.texts, two.texts])
      expect(candidates.map(&:reference)).to eq([seed.reference, one.reference, two.reference])
      expect(candidates.map(&:versions)).to eq([seed.versions, one.versions, two.versions])
      expect(candidates.map(&:candidate_id)).to eq([seed, one, two].map(&:candidate_id))
      expect(candidates.map(&:mean)).to eq([0.5, 0.25, 0.5])
      expect(candidates.map(&:metric_calls)).to eq([31, 40, 99])
      expect(candidates.last.scores.size).to eq(31)
    end

    it "reads how a run ended, its best candidate and its metric calls from its summary" do
      one = seed.child("answer.predict", "Answer briefly.", iteration: 1, parent: 0)
      lines = [seed_line, described_class.iteration(tuning_run_id: run, iteration: 1, ended_as: :accepted, totals:,
                                                    rng:, cursor:, parent: [seed, 0], component: "answer.predict",
                                                    child: { candidate: one, index: 1, minibatch: nil },
                                                    validation: pass(TuningRecords.validation_ids, 0.75, number: 2))]
      summary = described_class.summary(tuning_run_id: run, scope: {}, revision: 1, status: :finished,
                                        ended: :proposal, stop: { code: :metric_calls, detail: nil }, iterations: 2,
                                        candidates: 2, metric_calls_used: 70, validation_passes: 2,
                                        usage: { cost_nanos: 1, cost_complete: true, provider_calls: 70,
                                                 reflection_calls: 1 },
                                        seed: [seed, 0, 0.5], best: [one, 1, 0.75])
      record = described_class.new(header:, lines:, summary:)
      running = described_class.new(header:, lines:, summary: nil)

      expect([record.status, record.ended, record.best.candidate_id, record.metric_calls_used])
        .to eq([:finished, :proposal, one.candidate_id, 70])
      expect([running.status, running.ended, running.best, running.metric_calls_used]).to eq([nil, nil, nil, nil])
    end
  end
end
