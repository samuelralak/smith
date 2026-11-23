# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "smith/evals"

# Datasets, their manifests and the split rule (slice-1a design 4.2, 8.2,
# 8.3), against the published example dataset, which the reference
# generator built and an independent implementation reproduced.
RSpec.describe Smith::Evals::Dataset do
  example_dir = File.expand_path("../../../docs/evals/examples/dataset/support-tickets", __dir__)

  around do |example|
    Dir.mktmpdir("smith-evals-dataset") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:example_lines) { File.readlines(File.join(example_dir, "samples.jsonl"), chomp: true).map { JSON.parse(_1) } }
  let(:example_manifest) { JSON.parse(File.read(File.join(example_dir, "manifest.json"))) }

  def folder(lines, name: "set")
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    File.binwrite(File.join(path, "samples.jsonl"), lines.map { "#{JSON.generate(_1)}\n" }.join)
    path
  end

  def build(path, **options)
    described_class.build_manifest(path, name: "set", holdout: 0.25, calibration: 0.05, seed: "seed-1", **options)
  end

  def example_build(path)
    allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 14, 12, 9))
    described_class.build_manifest(path, name: "support-tickets", holdout: 0.25, calibration: 0.05,
                                         seed: "support-tickets-2026-11",
                                         created_by: Smith::Evals::Actor.person("usr_51a8"))
  end

  describe "the example dataset" do
    it "is rebuilt with its four hashes, its version and its split (37 dev, 8 holdout, 3 calibration)" do
      manifest = example_build(folder(example_lines))

      expect(manifest.hashes).to eq(example_manifest["hashes"])
      expect(manifest.version).to eq("sha256:9e638e886bbbd1c95bebcd62098b1fb219d8df7290d273ae2de554ae681924cc")
      expect(manifest.split_assignment).to eq(example_manifest["split_assignment"])
      expect(manifest.split_counts).to eq("dev" => 37, "holdout" => 8, "calibration" => 3)
    end

    it "is written as the published manifest.json, byte for byte" do
      path = folder(example_lines)
      example_build(path)

      written = File.binread(File.join(path, "manifest.json"))
      expect(written).to eq(File.binread(File.join(example_dir, "manifest.json")))
    end

    it "loads, verified, its samples sorted by id within each split" do
      dataset = described_class.load(example_dir)

      expect([dataset.name, dataset.version, dataset.samples.size])
        .to eq(["support-tickets", example_manifest["version"], 48])
      expect(dataset.split(:dev).map(&:id)).to eq(example_manifest.dig("split_assignment", "dev"))
      expect(dataset.split("holdout").map(&:split).uniq).to eq([:holdout])
      expect(dataset.sample("t-0029").hand_split).to eq(:holdout)
      expect(dataset.sample("t-0002").input)
        .to eq(channel: "chat", text: "My parcel shows delivered but nothing arrived at my door.")
      expect(dataset).to be_frozen
    end
  end

  describe "the split" do
    let(:random) { Random.new(4242) }

    def random_lines(count, offset: 0, clusters: 12)
      Array.new(count) do |index|
        line = { "id" => format("s-%05d", index + offset), "input" => { "n" => index + offset } }
        line["cluster"] = "c-#{random.rand(clusters)}" if random.rand < 0.6
        line
      end
    end

    it "never moves an existing sample when samples are added" do
      first = random_lines(120)
      path = folder(first)
      before = build(path).split_assignment
      after = build(folder(first + random_lines(80, offset: 120))).split_assignment

      moved = before.flat_map { |split, ids| ids - after.fetch(split) }
      expect(before.values.sum(&:size)).to eq(120)
      expect(moved).to eq([])
    end

    it "assigns the same splits, and gives the same hashes, whatever order the samples come in" do
      in_order = build(folder(example_lines, name: "in-order"))
      shuffled = build(folder(example_lines.shuffle(random: Random.new(7)), name: "shuffled"))

      expect(shuffled.to_h.except("created_at")).to eq(in_order.to_h.except("created_at"))
    end

    it "keeps a cluster's samples together, and they follow the cluster key, not the id" do
      lines = random_lines(300)
      dataset = described_class.load(folder(lines).tap { build(_1) })
      by_cluster = dataset.samples.select(&:cluster).group_by(&:cluster).transform_values { _1.map(&:split).uniq }

      expect(by_cluster.values.map(&:size).uniq).to eq([1])
      expect(by_cluster.values.flatten.uniq.size).to be > 1
    end

    it "lets a hand-set split win over the rule, and warns when a cluster then straddles splits" do
      lines = random_lines(60, clusters: 3)
      rule = Smith::Evals::SplitRule.new(seed: "seed-1", holdout: 0.25, calibration: 0.05)
      target = lines.find { _1["cluster"] && rule.assign(id: _1["id"], cluster: _1["cluster"]) == "dev" }
      target["split"] = "holdout"
      manifest = build(folder(lines))

      expect(manifest.split_assignment["holdout"]).to include(target["id"])
      expect(manifest.hand_assigned).to eq(1)
      expect(manifest.warnings).to eq([{ code: "cluster_straddles_splits", cluster: target["cluster"],
                                         splits: %w[dev holdout] }])
      expect(JSON.parse(File.read(File.join(@dir, "set", "manifest.json")))).not_to have_key("warnings")
      expect(described_class.load(File.join(@dir, "set")).warnings).to eq(manifest.warnings)
    end

    it "orders samples by UTF-16 code units, as every other language does" do
      ids = ["t-\u{FF5E}", "t-\u{1F600}", "t-a"]
      dataset = described_class.load(folder(ids.map { { "id" => _1, "input" => 1 } }).tap { build(_1) })

      expect(dataset.samples.map(&:id)).to eq(["t-a", "t-\u{1F600}", "t-\u{FF5E}"])
    end

    it "keeps each share as the JSON number its manifest holds, whatever Numeric it was given" do
      exact = described_class.build_manifest(folder(example_lines, name: "exact"), name: "set", holdout: 1/4r,
                                                                                   calibration: -0.0, seed: "seed-1")
      plain = described_class.build_manifest(folder(example_lines, name: "plain"), name: "set", holdout: 0.25,
                                                                                   calibration: 0, seed: "seed-1")
      shares = exact.to_h.dig("split_rule", "shares")

      expect([shares, shares.values.map(&:class)]).to eq([{ "holdout" => 0.25, "calibration" => 0.0 }, [Float, Float]])
      expect(File.read(File.join(@dir, "exact", "manifest.json")))
        .to include(%("holdout": 0.25,\n), %("calibration": 0.0\n))
      expect(exact.to_h.except("created_at")).to eq(plain.to_h.except("created_at"))
    end
  end

  # Vectors an independent implementation computed from the design alone,
  # on what the example dataset never holds: synthetic and source, ids past
  # U+FFFF, and a host's samples with Symbol keys.
  describe "independent vectors" do
    it "hashes synthetic and source into the metadata part, ids in UTF-16 order" do
      lines = [{ "id" => "a", "input" => 1, "synthetic" => true },
               { "id" => "b", "input" => 2, "source" => { "kind" => "manual", "run_key" => "r1" } },
               { "id" => "\u{1F600}", "input" => 3 }, { "id" => "\u{FF5E}", "input" => 4 }]
      manifest = described_class.build_manifest(folder(lines), name: "set", holdout: 0, calibration: 0, seed: "s")

      expect(manifest.hashes["metadata"])
        .to eq("sha256:d9fb01ff80852674a87427c9c635729eeab9f12cdcc03372f3a340c2300616f1")
      expect(manifest.version).to eq("sha256:5a89589e9e6ce4ac4c6efe4483f04b805295692fbf639ac795962eb5d34d3eb4")
    end

    it "takes a host's samples in their JSON form, so Symbol keys hash as String keys do" do
      strings = example_lines.first(6)
      symbols = strings.map { JSON.parse(JSON.generate(_1), symbolize_names: true) }
      built = [symbols, strings].map do |samples|
        Smith::Evals::DatasetManifest.build(samples, name: "set", holdout: 0.25, calibration: 0.05, seed: "seed-1")
      end

      expect(built.map { _1.to_h.except("created_at") }.uniq.size).to eq(1)
    end
  end

  describe "rebuilding under another split rule" do
    let(:lines) { (1..40).map { { "id" => "s#{_1}", "input" => { "x" => _1 } } } }

    def rebuild(path, seed:, holdout: 0.25, **options)
      described_class.build_manifest(path, name: "set", holdout:, calibration: 0.05, seed:, **options)
    end

    it "is refused unless a re-split is asked for, so no sample moves silently" do
      path = folder(lines)
      first = rebuild(path, seed: "seed-A")

      [{ seed: "seed-B" }, { seed: "seed-A", holdout: 0.05 }, { seed: "seed-A", holdout: 0.5 }].each do |rule|
        expect { rebuild(path, **rule) }
          .to raise_error(ArgumentError, /split rule differs from the manifest's.*resplit: true/)
      end
      expect(JSON.parse(File.read(File.join(path, "manifest.json")))["version"]).to eq(first.version)
      expect(rebuild(path, seed: "seed-A", resplit: true).resplits).to eq([])
    end

    it "redraws the splits when asked, warns of every sample that moved and records the re-split for good" do
      path = folder(lines)
      first = rebuild(path, seed: "seed-A")
      redrawn = rebuild(path, seed: "seed-B", resplit: true, created_by: Smith::Evals::Actor.person("usr_1"))
      moved = redrawn.warnings.to_h { [[_1[:from], _1[:to]], _1[:ids].size] }

      expect(moved).to eq(%w[dev holdout] => 7, %w[dev calibration] => 2, %w[holdout dev] => 7,
                          %w[calibration holdout] => 1)
      expect(redrawn.warnings.map { _1[:code] }.uniq).to eq(["samples_moved"])
      expect(redrawn.resplits).to eq([{ "at" => redrawn.created_at, "by" => { "kind" => "person", "id" => "usr_1" },
                                        "previous_version" => first.version,
                                        "previous_split_rule" => first.to_h["split_rule"] }])
      File.open(File.join(path, "samples.jsonl"), "a") { _1.write(%({"id":"s41","input":{"x":41}}\n)) }
      later = rebuild(path, seed: "seed-B")

      expect([later.resplits, later.previous_version]).to eq([redrawn.resplits, redrawn.version])
      expect(described_class.load(path).manifest.resplits).to eq(redrawn.resplits)
    end

    it "keeps every re-split, oldest first, when the rule is redrawn twice" do
      path = folder(lines)
      first = rebuild(path, seed: "seed-A")
      second = rebuild(path, seed: "seed-B", resplit: true)
      third = rebuild(path, seed: "seed-C", holdout: 0.5, resplit: true)

      expect(third.resplits.map { _1.slice("previous_version", "previous_split_rule") })
        .to eq([{ "previous_version" => first.version, "previous_split_rule" => first.to_h["split_rule"] },
                { "previous_version" => second.version, "previous_split_rule" => second.to_h["split_rule"] }])
      expect(third.resplits.first).to eq(second.resplits.first)
      expect(described_class.load(path).manifest.resplits).to eq(third.resplits)
    end

    it "warns of a sample a new hand-set split moved, on any rebuild" do
      path = folder(lines)
      first = rebuild(path, seed: "seed-A")
      moving = lines.find { |line| first.split_assignment["dev"].include?(line["id"]) }
      changed = lines.map { _1["id"] == moving["id"] ? _1.merge("split" => "holdout") : _1 }
      File.binwrite(File.join(path, "samples.jsonl"), changed.map { "#{JSON.generate(_1)}\n" }.join)

      expect(rebuild(path, seed: "seed-A").warnings)
        .to eq([{ code: "samples_moved", from: "dev", to: "holdout", ids: [moving["id"]] }])
    end
  end

  describe "the hashes" do
    it "change only the labels hash and the version when one label changes" do
      before = build(folder(example_lines, name: "a"))
      changed = example_lines.map(&:dup)
      changed[4] = changed[4].merge("expected" => { "category" => "billing", "priority" => "low" })
      after = build(folder(changed, name: "b"))

      expect(%w[inputs labels splits metadata].reject { before.hashes[_1] == after.hashes[_1] }).to eq(["labels"])
      expect(after.version).not_to eq(before.version)
    end

    it "hash a null field as an absent one" do
      optional = %w[expected label cluster tags synthetic source metadata split erasure_key expires_at keep added_at]
      nulls = example_lines.map { |line| optional.to_h { [_1, nil] }.merge(line) }

      expect(nulls[2]).to include("id" => "t-0003", "synthetic" => nil, "tags" => nil)
      expect(build(folder(nulls, name: "nulls")).hashes).to eq(build(folder(example_lines, name: "plain")).hashes)
    end

    it "leave out the operational fields" do
      kept = example_lines.map do |line|
        line.merge("erasure_key" => "other", "added_at" => "2026-11-01T00:00:00Z", "keep" => true)
      end

      expect(build(folder(kept, name: "kept")).version).to eq(build(folder(example_lines)).version)
    end
  end

  describe "the manifest" do
    it "counts every label kind, a disputed one included, and retention" do
      lines = example_lines.first(5).map(&:dup)
      lines[0]["label"] = { "kind" => "disputed", "raters" => %w[usr_1 usr_2] }
      lines[1].delete("label")
      lines[2]["expires_at"] = "2027-01-01T00:00:00Z"
      lines[3]["keep"] = true
      manifest = build(folder(lines))

      expect(manifest.labels).to eq("human" => 3, "ai" => 0, "adjudicated" => 0, "disputed" => 1, "none" => 1)
      expect(manifest.retention).to eq("expiring" => 1, "kept" => 1)
      expect(manifest.clusters).to eq(4)
    end

    it "is written again unchanged but for created_at, and names the previous version when samples change" do
      path = folder(example_lines)
      first = build(path, created_by: Smith::Evals::Actor.service("svc_1"))
      again = build(path, created_by: Smith::Evals::Actor.service("svc_1"))
      File.open(File.join(path, "samples.jsonl"), "a") { _1.write(%({"id":"t-9999","input":{"text":"new"}}\n)) }
      changed = build(path)

      expect(again.to_h.except("created_at")).to eq(first.to_h.except("created_at"))
      expect([first.previous_version, again.previous_version]).to eq([nil, nil])
      expect(changed.previous_version).to eq(first.version)
      expect(changed.sample_count).to eq(49)
    end

    # json before 2.8 writes an empty Array over three lines; the stub
    # stands in for it.
    it "writes an empty list as [] whatever the json version" do
      allow(JSON).to receive(:pretty_generate).and_wrap_original do |original, *args|
        original.call(*args).gsub("[]", "[\n\n    ]")
      end
      build(folder(example_lines.first(3)), holdout: 0, calibration: 0)
      text = File.read(File.join(@dir, "set", "manifest.json"))

      expect(text).to include(%("holdout": [],\n), %("resplits": []\n))
      expect(text).not_to match(/\[\s+\]/)
    end

    it "refuses duplicate ids, an empty set and a production run sample with no expiry" do
      expect { build(folder([{ "id" => "a", "input" => 1 }, { "id" => "a", "input" => 2 }])) }
        .to raise_error(Smith::Evals::DatasetInvalid, /sample id "a" appears twice/)
      expect { build(folder([])) }.to raise_error(Smith::Evals::DatasetInvalid, /holds no sample/)
      expect { build(folder([{ "id" => "a", "input" => 1, "source" => { "kind" => "production_run" } }])) }
        .to raise_error(Smith::Evals::DatasetInvalid, /production_run sample needs expires_at or keep/)
    end
  end

  describe "loading" do
    def built(lines = example_lines)
      folder(lines).tap { build(_1) }
    end

    it "refuses samples changed since the manifest, naming the part" do
      path = built
      lines = example_lines.map(&:dup)
      lines[3] = lines[3].merge("input" => { "channel" => "chat", "text" => "changed" })
      File.binwrite(File.join(path, "samples.jsonl"), lines.map { "#{JSON.generate(_1)}\n" }.join)

      expect { described_class.load(path) }.to raise_error(Smith::Evals::DatasetChanged) { |error|
        expect(error.parts).to eq(%w[inputs version])
        expect(error.message).not_to include("changed")
      }
    end

    it "refuses a manifest whose split assignment or counts were edited by hand" do
      path = built
      manifest = JSON.parse(File.read(File.join(path, "manifest.json")))
      manifest["split_assignment"]["dev"].pop
      manifest["split_counts"]["dev"] -= 1
      File.write(File.join(path, "manifest.json"), JSON.generate(manifest))

      expect { described_class.load(path) }.to raise_error(Smith::Evals::DatasetChanged) { |error|
        expect(error.parts).to eq(%w[split_assignment split_counts])
      }
    end

    it "refuses each derived count edited by hand, naming it" do
      path = built
      written = File.read(File.join(path, "manifest.json"))
      {
        "sample_count" => ->(m) { m["sample_count"] += 1 }, "hand_assigned" => ->(m) { m["hand_assigned"] += 1 },
        "clusters" => ->(m) { m["clusters"] -= 1 }, "labels" => ->(m) { m["labels"]["none"] += 1 },
        "retention" => ->(m) { m["retention"]["kept"] += 1 }
      }.each do |field, edit|
        File.write(File.join(path, "manifest.json"), JSON.generate(JSON.parse(written).tap(&edit)))
        expect { described_class.load(path) }.to raise_error(Smith::Evals::DatasetChanged) { expect(_1.parts).to eq([field]) }
      end
    end

    it "ignores fields it does not know, inside the counts, the hashes and the rule too" do
      path = built
      manifest = JSON.parse(File.read(File.join(path, "manifest.json")))
      manifest["labels"]["reviewed"] = 0
      manifest["retention"]["archived"] = 2
      manifest["split_counts"]["later"] = 1
      manifest["split_assignment"]["later"] = ["t-0001"]
      manifest["hashes"]["later"] = "sha256:#{"0" * 64}"
      manifest["split_rule"]["later"] = true
      manifest["split_rule"]["shares"]["later"] = 0.5
      manifest["later"] = { "x" => 1 }
      File.write(File.join(path, "manifest.json"), JSON.generate(manifest))

      expect(described_class.load(path).version).to eq(manifest["version"])
    end

    it "refuses a dataset whose version is not the one pinned" do
      path = built
      expect { described_class.load(path, version: "sha256:#{"0" * 64}") }
        .to raise_error(Smith::Evals::DatasetChanged, /pinned/) { expect(_1.parts).to eq(["version"]) }
      expect(described_class.load(path, version: build(path).version).name).to eq("set")
    end

    it "refuses a malformed samples file by line number, never echoing the line" do
      path = built
      {
        %({"id":"a","input":"secret"\n) => "samples.jsonl line 1: not valid JSON",
        %({"id":"a","input":1,"input":2}\n) => "samples.jsonl line 1: a key appears twice",
        %({"id":"a","input":"x"}\n{"id":"b","input":12345678901234567890}\n) =>
          "samples.jsonl line 2: canonical JSON integers are at most 2**53 - 1 in size",
        %({"id":"a","input":"x"}\n\n{"id":"b","input":"y","tags":["Bad"]}\n) =>
          "samples.jsonl line 3: /tags/0: is a tag",
        "\xFF\n" => "samples.jsonl line 1: not UTF-8",
        %({"id":"a","input":"#{"x" * Smith::Evals::FileDataset::MAX_LINE_BYTES}"}\n) =>
          "samples.jsonl line 1: longer than 4194304 bytes",
        %({"id":"a","input":#{"[" * 64}"secret"#{"]" * 64}}\n) => "samples.jsonl line 1: nested deeper than 64 levels",
        "\u0000\u0000\n" => "samples.jsonl line 1: not valid JSON",
        "null\n" => "samples.jsonl line 1: a sample is a JSON object"
      }.each do |text, message|
        File.binwrite(File.join(path, "samples.jsonl"), text)
        expect { described_class.load(path) }.to raise_error(Smith::Evals::DatasetInvalid) { |error|
          expect(error.message).to include(message)
          expect(error.message).not_to include("secret")
        }
      end
    end

    # json 2.11 and 2.12 keep the last of two equal keys before any object
    # class sees them; the stub parses as they do.
    it "refuses a repeated key whatever the json gem keeps, an escaped twin included" do
      allow(JSON).to receive(:parse).and_wrap_original do |original, text, **options|
        original.call(text, **options.except(:object_class), allow_duplicate_key: true)
      end
      path = folder([{ "id" => "a", "input" => 1 }])
      [%({"id":"a","input":1,"input":2}), %({"id":"a","input":{"k":1,"k":1}}),
       %({"id":"a","input":[{"k":1},{"k":1,"k":2}]}), %({"id":"a","input":{"a":1,"\\u0061":2}}),
       %({"id":"a","input":{"/":1,"\\/":2}}), %({"id":"a","input":{"\u{1F600}":1,"\\ud83d\\ude00":2}}),
       %({"id":"a","input":{"x":{"k":1},"k":{"k":1,"\\u006b":2}}})].each do |text|
        File.binwrite(File.join(path, "samples.jsonl"), "#{text}\n")
        expect { build(path) }
          .to raise_error(Smith::Evals::DatasetInvalid, "samples.jsonl line 1: a key appears twice"), text
      end
      File.binwrite(File.join(path, "samples.jsonl"),
                    %({"id":"a","input":{"a":1,"A":2,"é":3,"é":4,"k":{"k":{"k":[{"k":1}]}}}}\n))
      expect(build(path).sample_count).to eq(1)
    end

    # json 2.x reads a comment, and older 2.x an unknown escape; JSON allows
    # neither, so no version may.
    it "refuses a comment or an unknown escape whatever the json gem reads" do
      path = folder([{ "id" => "a", "input" => 1 }])
      texts = [%({"id":"a","input":1 /* note */}), %({"id":"a","input":1} // note), %({"id":"a",/**/"input":1}),
               %({"id":"a","input":"\\q"}), %({"id":"a","input":{"\\q":1}})]
      refusal = lambda do |text|
        File.binwrite(File.join(path, "samples.jsonl"), "#{text}\n")
        expect { build(path) }
          .to raise_error(Smith::Evals::DatasetInvalid, "samples.jsonl line 1: not valid JSON"), text
      end
      texts.each(&refusal)
      # As json up to 2.13 reads them (2.20 and 3.x refuse some first), so the
      # check on the raw text is exercised whatever the lockfile holds.
      allow(JSON).to receive(:parse).and_wrap_original do |original, text, **options|
        original.call(text.gsub(%r{/\*.*?\*/|//[^"]*\z}, "").gsub("\\q", "q"), **options)
      end
      texts.each(&refusal)
      expect(JSON.parse(%({"a":"\\q"} // c))).to eq("a" => "q")

      allow(JSON).to receive(:parse).and_call_original
      File.binwrite(File.join(path, "samples.jsonl"), %({"id":"a","input":"/* kept */ \\/ \\u00e9 \\" // kept"}\n))
      expect(build(path).sample_count).to eq(1)
    end

    it "reads a line of exactly 4 MiB before its CRLF, and refuses one byte more" do
      path = built
      wrapper = '{"id":"a","input":""}'.bytesize
      line = ->(extra) { %({"id":"a","input":"#{"x" * (Smith::Evals::FileDataset::MAX_LINE_BYTES - wrapper + extra)}"}) }
      File.binwrite(File.join(path, "samples.jsonl"), "#{line.call(0)}\r\n")
      expect(build(path).sample_count).to eq(1)

      File.binwrite(File.join(path, "samples.jsonl"), "#{line.call(1)}\r\n")
      expect { build(path) }
        .to raise_error(Smith::Evals::DatasetInvalid, "samples.jsonl line 1: longer than 4194304 bytes")
    end

    it "refuses a samples_file naming a control character, never echoing it" do
      path = built
      manifest = JSON.parse(File.read(File.join(path, "manifest.json")))
      ["samples.jsonl\n", "a\u0000b", "tab\tname", "del\u007f"].each do |name|
        File.write(File.join(path, "manifest.json"), JSON.generate(manifest.merge("samples_file" => name)))
        expect { described_class.load(path) }
          .to raise_error(Smith::Evals::DatasetInvalid,
                          "manifest.json: /samples_file: is a file name in the dataset's folder")
      end
    end

    it "refuses a file linked from outside the folder, and reads one linked from inside it" do
      outside = folder(example_lines, name: "outside").tap { build(_1) }
      linked = File.join(@dir, "linked").tap { FileUtils.mkdir_p(_1) }
      File.symlink(File.join(outside, "samples.jsonl"), File.join(linked, "samples.jsonl"))
      expect { build(linked) }
        .to raise_error(Smith::Evals::DatasetInvalid, "samples.jsonl is a link outside the dataset's folder")

      File.delete(File.join(linked, "samples.jsonl"))
      FileUtils.cp(File.join(outside, "samples.jsonl"), File.join(linked, "all.jsonl"))
      File.symlink("all.jsonl", File.join(linked, "samples.jsonl"))
      expect(described_class.load(linked.tap { build(_1) }).samples.size).to eq(48)

      File.delete(File.join(linked, "manifest.json"))
      File.symlink(File.join(outside, "manifest.json"), File.join(linked, "manifest.json"))
      expect { described_class.load(linked) }
        .to raise_error(Smith::Evals::DatasetInvalid, "manifest.json is a link outside the dataset's folder")
    end

    it "refuses a file in a sibling folder whose name starts with the dataset folder's" do
      sibling = folder(example_lines, name: "ds-other")
      dataset = File.join(@dir, "ds").tap { FileUtils.mkdir_p(_1) }
      File.symlink(File.join(sibling, "samples.jsonl"), File.join(dataset, "samples.jsonl"))

      expect { build(dataset) }
        .to raise_error(Smith::Evals::DatasetInvalid, "samples.jsonl is a link outside the dataset's folder")
    end

    it "refuses a samples file or a manifest that is not a regular file, never blocking on a FIFO" do
      fifo = File.join(@dir, "fifo").tap { FileUtils.mkdir_p(_1) }
      File.mkfifo(File.join(fifo, "samples.jsonl"))
      piped = built
      File.delete(File.join(piped, "manifest.json"))
      File.mkfifo(File.join(piped, "manifest.json"))
      directory = File.join(@dir, "directory").tap { FileUtils.mkdir_p(File.join(_1, "samples.jsonl")) }
      script = <<~RUBY
        require "smith/evals"
        ARGV.each do |path|
          Smith::Evals::Dataset.build_manifest(path, name: "set", holdout: 0.25, calibration: 0.05, seed: "seed-1")
          puts "built"
        rescue Smith::Evals::DatasetInvalid => e
          puts e.message
        end
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      Open3.popen2(RbConfig.ruby, "-I", lib, "-e", script, fifo, piped, directory) do |input, output, waiter|
        input.close
        finished = waiter.join(60)
        Process.kill("KILL", waiter.pid) unless finished
        expect(finished).not_to be_nil, "the build blocked"
        expect(output.read.lines(chomp: true))
          .to eq(["samples.jsonl is not a regular file", "manifest.json is not a regular file",
                  "samples.jsonl is not a regular file"])
      end
    end

    it "refuses a missing folder or manifest, and a manifest not in its format" do
      expect { described_class.load(File.join(@dir, "none")) }
        .to raise_error(Smith::Evals::DatasetInvalid, /manifest.json/)
      path = built
      manifest = JSON.parse(File.read(File.join(path, "manifest.json")))
      File.write(File.join(path, "manifest.json"), JSON.generate(manifest.merge("format_version" => 2)))
      expect { described_class.load(path) }.to raise_error(Smith::Evals::DatasetInvalid, %r{/format_version: is 1})
      File.write(File.join(path, "manifest.json"), JSON.generate(manifest.merge("samples_file" => "../x.jsonl")))
      expect { described_class.load(path) }.to raise_error(Smith::Evals::DatasetInvalid, %r{/samples_file})
      File.write(File.join(path, "manifest.json"), JSON.generate(manifest.merge("resplits" => [{ "at" => nil }])))
      expect { described_class.load(path) }.to raise_error(Smith::Evals::DatasetInvalid, %r{/resplits/0: is an object})
    end

    it "loads a host source through manifest(scope:) and each_sample(scope:), verified the same way" do
      manifest = build(folder(example_lines)).to_h
      host = Class.new do
        attr_reader :scopes

        def initialize(manifest, lines)
          @manifest = manifest
          @lines = lines
          @scopes = []
        end

        def manifest(scope:)
          @scopes << scope
          @manifest
        end

        def each_sample(scope:, &)
          @scopes << scope
          @lines.each(&)
        end
      end
      source = host.new(manifest, example_lines)
      dataset = described_class.load(source, scope: { tenant: "ten_0193" })

      expect(dataset.version).to eq(manifest["version"])
      expect(source.scopes).to eq([{ "tenant" => "ten_0193" }] * 2)
      expect { described_class.load(host.new(manifest, example_lines.first(47)), scope: {}) }
        .to raise_error(Smith::Evals::DatasetChanged)
      expect { described_class.load(host.new(manifest, [{ "id" => "a" }]), scope: {}) }
        .to raise_error(Smith::Evals::DatasetInvalid, "sample 1: /input: is required")
      symbols = JSON.parse(JSON.generate(manifest), symbolize_names: true)
      expect(described_class.load(host.new(symbols, example_lines), scope: {}).version).to eq(manifest["version"])
    end
  end
end
