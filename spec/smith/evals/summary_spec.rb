# frozen_string_literal: true

require "json"
require "smith/evals"

# The summary (slice-1a design, 6.4; contracts' summary.schema.json), built
# from a run's header, launch lines and trial lines alone, so a resumed run,
# a stored record and the published examples all give the same one.
RSpec.describe Smith::Evals::Summary do
  examples = File.expand_path("../../../docs/evals/examples", __dir__)

  let(:dev) { Smith::Evals::Dataset.load(File.join(examples, "dataset/support-tickets")).split(:dev) }

  def read(folder, name) = File.read(File.join(folder, name), encoding: "UTF-8")
  def lines(folder, name) = read(folder, name).lines.map { JSON.parse(_1) }

  # Where two summaries differ: every key in the same order and every value
  # of the same JSON type and equal, except that a Float (an estimate's
  # interval, design effect or effective size) may differ by 1e-12, as
  # Smith's statistics and the reference agree (closed forms, design 7.0).
  def differences(actual, expected, path = "")
    return entries(actual, expected, path) if expected.is_a?(Hash) || expected.is_a?(Array)

    same?(actual, expected) ? [] : ["#{path}: #{actual.inspect}"]
  end

  def entries(actual, expected, path)
    keys = expected.is_a?(Hash) ? expected.keys : expected.each_index.to_a
    shape = actual.instance_of?(expected.class) && (actual.is_a?(Hash) ? actual.keys : actual.each_index.to_a) == keys
    return ["#{path}: shape"] unless shape

    keys.flat_map { differences(actual[_1], expected[_1], "#{path}/#{_1}") }
  end

  def same?(actual, expected)
    return actual.is_a?(Float) && (actual - expected).abs <= 1e-12 if expected.is_a?(Float)

    actual.instance_of?(expected.class) && actual == expected
  end

  def unlike(summary, published)
    differences(summary.except("gates", "gate_result"), published.except("gates", "gate_result"))
  end

  def built(folder, published, header: JSON.parse(read(folder, "header.json")), trials: lines(folder, "trials.jsonl"),
            **)
    described_class.build(header:, segments: lines(folder, "segments.jsonl"), lines: trials, samples: dev,
                          status: published.fetch("status"), stop: published.fetch("stop"),
                          ended_at: published.fetch("ended_at"), **)
  end

  describe "from the published trial lines" do
    %w[records/passing records/failing records/incomplete groups/compare-models/claude-haiku-4-5
       groups/compare-models/claude-sonnet-4-6 groups/compare-models/claude-opus-4-7].each do |name|
      it "gives #{name}'s summary, by_model included, its gates left to slice 1b.1" do
        folder = File.join(examples, name)
        published = JSON.parse(read(folder, "summary.json"))
        summary = built(folder, published)

        expect(unlike(summary, published)).to eq([])
        expect(summary.values_at("gates", "gate_result")).to eq([[], "none"])
        expect(EvalsSchema.errors(summary, schema: "summary", strict: true)).to eq([])
      end
    end

    it "gives the rerun record's revision 2 from every line, superseded ones included" do
      folder = File.join(examples, "records/failing-rerun")
      published = JSON.parse(read(folder, "summary.json"))
      summary = built(folder, published, revision: 2, reruns: published.fetch("reruns"))

      expect(unlike(summary, published)).to eq([])
    end
  end

  describe "results" do
    let(:folder) { File.join(examples, "records/passing") }
    let(:published) { JSON.parse(read(folder, "summary.json")) }
    let(:header) { JSON.parse(read(folder, "header.json")) }

    it "reads each estimate at the suite's confidence level" do
      header["statistics"]["level"] = 0.9
      at90 = built(folder, published, header:)["results"].first["estimate"]
      at95 = published["results"].first["estimate"]

      expect([at90["confidence"], at95["confidence"]]).to eq([0.9, 0.95])
      expect(at90["upper"] - at90["lower"]).to be < (at95["upper"] - at95["lower"])
    end

    # Design 4.4: pass_at_k reads k trials of a sample. A cancel after
    # every sample's first trial leaves each with one.
    it "leaves out of a pass_at_k result each sample with fewer than k counted trials, and counts it" do
      header["suite"]["manifest"]["scorers"].first["also"] = ["pass_at_3"]
      summary = built(folder, published, header:, trials: lines(folder, "trials.jsonl").first(40))
      result = summary["results"].find { _1["reducer"] == "pass_at_3" }

      expect(result.values_at("samples_uncounted", "trials_counted")).to eq([37, 0])
      expect(result["estimate"].values_at("n", "point", "warnings")).to eq([0, nil, ["no_samples"]])
      expect(EvalsSchema.errors(summary, schema: "summary", strict: true)).to eq([])
    end
  end

  describe "usage" do
    let(:folder) { File.join(examples, "records/failing") }
    let(:published) { JSON.parse(read(folder, "summary.json")) }

    def model(provider, name, calls, cost, complete: true, input: 0)
      { "provider" => provider, "model" => name, "provider_calls" => calls,
        "tokens" => { "input" => input, "output" => 0, "cache_read" => 0, "cache_write" => 0, "thinking" => 0 },
        "cost_nanos" => cost, "cost_complete" => complete }
    end

    def usage_of(entries)
      totals = entries.map { _1["tokens"] }.reduce { |sum, tokens| sum.merge(tokens) { |_key, a, b| a + b } }
      { "tokens" => totals, "cost_nanos" => entries.sum { _1["cost_nanos"] },
        "cost_complete" => entries.all? { _1["cost_complete"] },
        "provider_calls" => entries.sum { _1["provider_calls"] }, "by_model" => entries }
    end

    # The published run's lines, the first ones given usages of their own.
    def spending(*by_models)
      lines(folder, "trials.jsonl").each_with_index.map do |line, index|
        by_models[index] ? line.merge("usage" => usage_of(by_models[index])) : line
      end
    end

    it "sums every line's by_model by provider and model, an unknown model first, and sums to usage" do
      spent = spending([model("openai", "gpt-5-mini", 2, 30, input: 7), model(nil, nil, 1, 5, complete: false)],
                       [model("anthropic", "claude-haiku-4-5", 1, 11), model("openai", "gpt-5", 1, 13)],
                       [model("openai", "gpt-5-mini", 1, 17, input: 1)])
      usage = described_class.build(header: JSON.parse(read(folder, "header.json")),
                                    segments: lines(folder, "segments.jsonl"), lines: spent, samples: dev,
                                    status: "succeeded", stop: nil, ended_at: published["ended_at"])["usage"]
      by_model = usage["by_model"]

      expect(by_model.map { _1.values_at("provider", "model") })
        .to eq([[nil, nil], %w[anthropic claude-haiku-4-5], %w[openai gpt-5], %w[openai gpt-5-mini]])
      expect(by_model.first.values_at("provider_calls", "cost_nanos", "cost_complete")).to eq([1, 5, false])
      expect(by_model.last.values_at("provider_calls", "cost_nanos")).to eq([2 + 6 + 1, 30 + 17])
      expect(by_model.last["tokens"]["input"]).to eq(8)
      %w[cost_nanos provider_calls].each { |key| expect(by_model.sum { _1[key] }).to eq(usage[key]) }
      expect(by_model.map { _1["tokens"] }.reduce { |a, b| a.merge(b) { |_k, x, y| x + y } }).to eq(usage["tokens"])
      expect(usage["cost_complete"]).to be(false)
    end

    it "costs a sample only when every planned trial of it ran, from all its lines" do
      folder = File.join(examples, "records/incomplete")
      published = JSON.parse(read(folder, "summary.json"))
      usage = built(folder, published)["usage"]

      expect(usage.values_at("samples_costed", "cost_per_sample_nanos", "cost_per_1000_samples_nanos"))
        .to eq([0, nil, nil])
      expect(usage["cost_per_trial_nanos"]).to eq((Rational(usage["cost_nanos"], 53) + Rational(1, 2)).floor)
    end
  end

  describe "warnings and stops" do
    let(:folder) { File.join(examples, "records/failing") }
    let(:published) { JSON.parse(read(folder, "summary.json")) }

    it "counts the Smith and host code versions its launches ran on, when more than one" do
      segments = lines(folder, "segments.jsonl")
      segments[1]["environment"] = segments[1]["environment"].merge("host_code_version" => "5f00d1e")
      summary = described_class.build(header: JSON.parse(read(folder, "header.json")), segments:,
                                      lines: lines(folder, "trials.jsonl"), samples: dev, status: "succeeded",
                                      stop: nil, ended_at: published["ended_at"])

      expect(summary["warnings"]).to include({ "code" => "mixed_code_versions", "count" => 2 })
      expect(summary["segments"].map { _1["host_code_version"] }).to eq(%w[4e1d0a7 5f00d1e])
    end

    it "counts the trials that never started as not run, under the stop's code" do
      stop = { "reason" => { "code" => "cancelled", "by" => "operator", "detail" => nil },
               "actor" => { "kind" => "person", "id" => "usr_1" }, "at" => published["ended_at"], "trial_id" => nil }
      summary = described_class.build(header: JSON.parse(read(folder, "header.json")),
                                      segments: lines(folder, "segments.jsonl"),
                                      lines: lines(folder, "trials.jsonl").first(40), samples: dev,
                                      status: "cancelled", stop:, ended_at: published["ended_at"])

      expect(summary.values_at("status", "complete")).to eq(["cancelled", false])
      expect(summary["outcomes"]["not_run"]).to eq(111 - 40)
      expect(summary["causes"]["not_run"]).to eq("cancelled" => 71)
      expect(summary["outcomes"].values.sum).to eq(111)
      expect(EvalsSchema.errors(summary, schema: "summary", strict: true)).to eq([])
    end
  end
end
