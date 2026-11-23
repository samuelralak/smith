# frozen_string_literal: true

require "smith/evals"

# One sample line (contracts' sample.schema.json, smith.evals.sample/1) as a
# scorer reads it: symbol keys, frozen, with its assigned split.
RSpec.describe Smith::Evals::Sample do
  let(:line) do
    { "id" => "t-0002", "input" => { "channel" => "chat", "text" => "My parcel shows delivered." },
      "expected" => { "category" => "shipping", "priority" => "urgent" },
      "label" => { "kind" => "human", "by" => "usr_51a8", "at" => "2026-11-18T10:02:00.000Z" },
      "cluster" => "cus-1002", "tags" => ["missing_parcel"], "erasure_key" => "person:cus-1002" }
  end

  it "reads the line with symbol keys, frozen, and its assigned split" do
    sample = described_class.new(line, split: "dev")

    expect(sample.id).to eq("t-0002")
    expect(sample.input).to eq(channel: "chat", text: "My parcel shows delivered.")
    expect(sample.expected).to eq(category: "shipping", priority: "urgent")
    expect(sample.label).to eq(kind: "human", by: "usr_51a8", at: "2026-11-18T10:02:00.000Z")
    expect([sample.split, sample.hand_split, sample.cluster, sample.tags])
      .to eq([:dev, nil, "cus-1002", ["missing_parcel"]])
    expect([sample.metadata, sample.synthetic, sample.source, sample.erasure_key])
      .to eq([{}, nil, nil, "person:cus-1002"])
    expect(sample.input).to be_frozen
    expect(sample.input[:text]).to be_frozen
    expect(sample.to_h).to eq(line)
    expect(sample.to_h).to be_frozen
  end

  it "reads absent and null fields alike, and a hand-set split" do
    line = { "id" => "a", "input" => "text", "split" => "holdout", "tags" => nil }
    sample = described_class.new(line, split: :holdout)

    expect([sample.expected, sample.label, sample.cluster, sample.tags, sample.metadata])
      .to eq([nil, nil, nil, [], {}])
    expect([sample.split, sample.hand_split]).to eq(%i[holdout holdout])
  end

  describe ".check!" do
    def refusal(line)
      described_class.check!(line, where: "samples.jsonl line 7")
      nil
    rescue Smith::Evals::DatasetInvalid => e
      e.message
    end

    it "accepts the line and every optional field at its bounds" do
      full = line.merge("split" => nil, "synthetic" => true, "metadata" => { "x" => 1 }, "keep" => nil,
                        "source" => { "kind" => "import", "run_key" => "r", "step" => "s",
                                      "at" => "2026-11-18T10:02:00Z" },
                        "expires_at" => "2027-01-01T00:00:00.123456Z", "added_at" => nil, "cluster" => "c" * 256)

      expect(refusal(full)).to be_nil
    end

    it "refuses each malformed field by its path and line, never echoing a value" do
      cases = {
        "a JSON array" => [[], "samples.jsonl line 7: a sample is a JSON object"],
        "no id" => [line.except("id"), "samples.jsonl line 7: /id: is required"],
        "a control character in the id" => [line.merge("id" => "t\u0001"), "/id: is a String of 1 to 256 characters"],
        "no input" => [line.except("input"), "/input: is required"],
        "an unknown label kind" => [line.merge("label" => { "kind" => "guess" }),
                                    "/label/kind: is human, ai, adjudicated or disputed"],
        "a label without a kind" => [line.merge("label" => { "by" => "x" }), "/label/kind: is required"],
        "an unknown split" => [line.merge("split" => "test"), "/split: is null, dev, holdout or calibration"],
        "an empty cluster" => [line.merge("cluster" => ""), "/cluster: is null or a String of 1 to 256 characters"],
        "a bad tag" => [line.merge("tags" => ["Refund"]), "/tags/0: is a tag"],
        "a repeated tag" => [line.merge("tags" => %w[a a]), "/tags: holds a tag twice"],
        "a text synthetic" => [line.merge("synthetic" => "yes"), "/synthetic: is null, true or false"],
        "a source without a kind" => [line.merge("source" => {}), "/source/kind: is required"],
        "array metadata" => [line.merge("metadata" => [1]), "/metadata: is null or a JSON object"],
        "a local time" => [line.merge("expires_at" => "2027-01-01T00:00:00+01:00"),
                           "/expires_at: is null or a UTC time"],
        "a text keep" => [line.merge("keep" => 1), "/keep: is null, true or false"],
        "a production run kept forever by accident" => [
          line.merge("source" => { "kind" => "production_run" }),
          "/source: a production_run sample needs expires_at or keep: true"
        ]
      }

      cases.each do |name, (bad, message)|
        found = refusal(bad)
        expect(found).to include(message), "#{name}: #{found.inspect}"
        expect(found).to start_with("samples.jsonl line 7: "), name
        expect(found).not_to include("My parcel"), name
      end
    end

    # A null is absent only at the top level; the published schema refuses
    # one inside label or source, so the Ruby does too.
    it "refuses a null inside label or source, by its path" do
      label = { "kind" => "human", "by" => "usr_1" }
      source = { "kind" => "manual" }
      cases = %w[by model judge_version settled_by raters at]
              .to_h { ["/label/#{_1}", line.merge("label" => label.merge(_1 => nil))] }
              .merge(%w[run_key step at].to_h { ["/source/#{_1}", line.merge("source" => source.merge(_1 => nil))] })

      cases.each do |path, bad|
        expect(refusal(bad)).to start_with("samples.jsonl line 7: #{path}: is "), path
      end
      expect(refusal({ "id" => "a", "input" => 1, "label" => { "kind" => "human", "by" => nil } })).not_to be_nil
    end

    it "keeps a production run sample that expires or is kept" do
      expect(refusal(line.merge("source" => { "kind" => "production_run" }, "keep" => true))).to be_nil
      expect(refusal(line.merge("source" => { "kind" => "production_run" }, "expires_at" => "2027-01-01T00:00:00Z")))
        .to be_nil
    end
  end
end
