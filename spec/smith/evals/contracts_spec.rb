# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "smith/evals"

# The dataset, sample and suite manifest contracts (docs/evals/schemas,
# copied from the slice 1a contracts): every published example, and every
# document this slice's Ruby writes, valid as published and in the strict
# mode that refuses unknown fields.
RSpec.describe "The dataset and suite contracts" do
  examples = File.expand_path("../../../docs/evals/examples", __dir__)

  def valid!(document, schema)
    %i[open strict].each do |mode|
      expect(EvalsSchema.errors(document, schema:, strict: mode == :strict)).to eq([]), "#{schema} (#{mode})"
    end
  end

  it "publishes each schema as valid JSON Schema 2020-12, by its URN" do
    require "json_schemer"

    expect(EvalsSchema.documents.keys).to include("urn:smith:evals:1:sample", "urn:smith:evals:1:dataset-manifest",
                                                  "urn:smith:evals:1:suite-manifest", "urn:smith:evals:1:common")
    EvalsSchema.documents.each_value { expect(JSONSchemer.valid_schema?(_1)).to be(true), _1["$id"] }
  end

  it "validates every published dataset and suite example" do
    valid!(JSON.parse(File.read(File.join(examples, "dataset/support-tickets/manifest.json"))), "dataset-manifest")
    File.foreach(File.join(examples, "dataset/support-tickets/samples.jsonl")) { valid!(JSON.parse(_1), "sample") }
    Dir[File.join(examples, "suite/**/*.json")].each { valid!(JSON.parse(File.read(_1)), "suite-manifest") }
  end

  # B1 of the slice 1a.2 review: a null inside label or source is refused by
  # the schema, so the line rules refuse it too.
  it "refuses, as the sample rules do, a null inside label or source" do
    lines = %w[by model judge_version settled_by raters at].map { { "label" => { "kind" => "human", _1 => nil } } } +
            %w[run_key step at].map { { "source" => { "kind" => "manual", _1 => nil } } }

    lines.each do |fields|
      line = { "id" => "a", "input" => 1 }.merge(fields)
      expect(EvalsSchema.errors(line, schema: "sample", strict: false)).not_to be_empty, fields.inspect
      expect { Smith::Evals::Sample.check!(line, where: "line") }.to raise_error(Smith::Evals::DatasetInvalid)
    end
  end

  it "refuses an unknown field only in strict mode" do
    sample = { "id" => "a", "input" => 1, "comment" => "x" }

    expect(EvalsSchema.errors(sample, schema: "sample", strict: false)).to eq([])
    expect(EvalsSchema.errors(sample, schema: "sample", strict: true)).not_to be_empty
  end

  it "validates the manifests and samples this slice writes" do
    Dir.mktmpdir do |dir|
      lines = [
        { "id" => "a", "input" => { "q" => "x" }, "expected" => "y", "cluster" => "c1", "tags" => ["t:1"],
          "label" => { "kind" => "disputed", "raters" => %w[usr_1 usr_2], "at" => "2026-11-18T10:02:00Z" } },
        { "id" => "b", "input" => [1, 2.5], "split" => "holdout", "synthetic" => true, "metadata" => { "m" => 1 },
          "source" => { "kind" => "production_run", "run_key" => "run-1", "step" => "triage" },
          "expires_at" => "2027-01-01T00:00:00Z", "erasure_key" => "person:1" },
        { "id" => "c", "input" => nil,
          "label" => { "kind" => "ai", "by" => "judge", "model" => "m", "judge_version" => "1" },
          "keep" => true, "added_at" => "2026-11-01T00:00:00.5Z" }
      ]
      File.binwrite(File.join(dir, "samples.jsonl"), lines.map { "#{JSON.generate(_1)}\n" }.join)
      manifest = Smith::Evals::Dataset.build_manifest(dir, name: "mixed", holdout: 0.5, calibration: 0.1, seed: "s",
                                                           created_by: Smith::Evals::Actor.policy("auto"))

      valid!(manifest.to_h, "dataset-manifest")
      valid!(JSON.parse(File.read(File.join(dir, "manifest.json"))), "dataset-manifest")
      Smith::Evals::Dataset.load(dir).samples.each { valid!(_1.to_h, "sample") }
      redrawn = Smith::Evals::Dataset.build_manifest(dir, name: "mixed", holdout: 0.25, calibration: 0, seed: "t",
                                                          resplit: true)
      expect(redrawn.resplits.size).to eq(1)
      valid!(JSON.parse(File.read(File.join(dir, "manifest.json"))), "dataset-manifest")
    end
  end

  it "validates the suite manifests the DSL writes" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(examples, "dataset/support-tickets"), File.join(dir, "tickets"))
      stub_const("Triage", Class.new(Smith::Workflow))
      tone = Class.new(Smith::Evals::Scorer) do
        scorer_name :tone
        version 2
        def score(*) = Smith::Evals::Score.pass
      end
      suite = Class.new(Smith::Evals::Suite) do
        suite_name "contracts.demo"
        dataset File.join(dir, "tickets")
        narrow tags_any: %w[refund]
        subject workflow: Triage, input: :input.to_proc, keep: %i[triage], until: :triaged, version: 3
        trials 4, reduce: :any
        infrastructure_errors IOError, Errno::ECONNREFUSED
        scorer(:quality, version: 1, scale: :continuous) { |*| Smith::Evals::Score.value(0.5) }
        scorer tone, also: [{ pass_at: 2 }, :mean]
        statistics level: 0.9
        recording content: false
        gate :tone_floor, scorer: :tone, at_least: 0.7, reducer: { pass_at: 2 }
        labels accept: :human_only
      end

      valid!(suite.manifest, "suite-manifest")
      expect(suite.manifest.dig("trials", "infrastructure_errors")).to eq(%w[Errno::ECONNREFUSED IOError])
    end
  end
end
